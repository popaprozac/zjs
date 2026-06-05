// jit_poc.c — STANDALONE copy-and-patch proof-of-concept for the zjs JIT
// Phase-1 substrate spike. NOT wired into the engine.
//
// Goal: prove the *mechanism* of copy-and-patch codegen works on macOS
// arm64 (Apple Silicon) under W^X. Concretely it:
//
//   1. "Stitches" two micro-stencils (a constant-load with a patchable
//      immediate HOLE, and an integer-sum loop with a back-edge BRANCH)
//      into one function  uint64_t f(void)  that computes sum(0..N-1).
//   2. Allocates an executable buffer with mmap + MAP_JIT (REQUIRED on
//      Apple Silicon — a plain PROT_EXEC anonymous mapping is forbidden
//      by W^X / the hardened runtime).
//   3. Toggles per-thread write protection OFF with
//      pthread_jit_write_protect_np(0), COPIES the stencil words in, then
//      PATCHES the immediate hole with the real N (the relocation step),
//      and toggles protection back ON (page becomes executable).
//   4. Flushes the i-cache (sys_icache_invalidate — mandatory on arm64
//      after writing code) and CALLS the stitched code, comparing the
//      result against the closed-form sum.
//
// Prints PASS iff the JIT'd result matches and the hole sentinel was
// present before patching (proving we really patched a hole, not baked
// the constant at emit time).
//
// Build & run:
//   clang -O2 -o /tmp/jit_poc tools/jit_poc.c
//   /tmp/jit_poc
//
// A CLI binary from Terminal is allowed to JIT for free; an app under the
// hardened runtime needs the com.apple.security.cs.allow-jit entitlement —
// exactly the platform gate the JIT design study calls out.

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>   // sys_icache_invalidate

// --- arm64 instruction encoders (64-bit X registers) -----------------------
// MOVZ Xd, #imm16            -> 0xD2800000 | (imm16<<5) | Rd
// MOVK Xd, #imm16, LSL 16    -> 0xF2A00000 | (imm16<<5) | Rd
// ADD  Xd, Xn, Xm            -> 0x8B000000 | (Rm<<16) | (Rn<<5) | Rd
// ADD  Xd, Xn, #imm12        -> 0x91000000 | (imm12<<10) | (Rn<<5) | Rd
// CMP  Xn, Xm  (SUBS XZR,..) -> 0xEB00001F | (Rm<<16) | (Rn<<5)
// B.cond label               -> 0x54000000 | (imm19<<5) | cond  (imm19 in insns)
// B    label                 -> 0x14000000 | (imm26)            (imm26 in insns)
// RET (x30)                  -> 0xD65F03C0
#define MOVZ_X(Rd, imm16)       (0xD2800000u | ((uint32_t)(imm16) << 5) | (uint32_t)(Rd))
#define MOVK_X_LSL16(Rd, imm16) (0xF2A00000u | ((uint32_t)(imm16) << 5) | (uint32_t)(Rd))
#define ADD_X(Rd, Rn, Rm)       (0x8B000000u | ((uint32_t)(Rm) << 16) | ((uint32_t)(Rn) << 5) | (uint32_t)(Rd))
#define ADD_X_IMM(Rd, Rn, imm)  (0x91000000u | ((uint32_t)(imm) << 10) | ((uint32_t)(Rn) << 5) | (uint32_t)(Rd))
#define CMP_X_REG(Rn, Rm)       (0xEB00001Fu | ((uint32_t)(Rm) << 16) | ((uint32_t)(Rn) << 5))
#define BCOND(cond, off19)      (0x54000000u | (((uint32_t)(off19) & 0x7FFFFu) << 5) | (uint32_t)(cond))
#define B_UNCOND(off26)         (0x14000000u | ((uint32_t)(off26) & 0x3FFFFFFu))
#define RET_X30                 (0xD65F03C0u)
#define COND_GE                 (0xAu)
#define XZR                     31u

// Sentinel immediate written into the constant-load hole at emit time, so we
// can verify at runtime that a hole really existed before we patched it.
#define HOLE_SENTINEL 0xABCDu

int main(void) {
    const uint64_t N = 1000000;                 // sum 0..N-1
    const uint64_t EXPECTED = N * (N - 1) / 2;  // closed form = 499999500000

    // -- (1) Assemble the stencil sequence into a host scratch buffer.
    //
    // Register use: x0 = result, x1 = acc, x2 = i, x3 = N.
    //
    //  [0] MOVZ x1, #0              ; acc = 0          (init stencil)
    //  [1] MOVZ x2, #0              ; i   = 0          (init stencil)
    //  [2] MOVZ x3, #<HOLE lo16>    ; N low half       <-- HOLE A (immediate)
    //  [3] MOVK x3, #<HOLE hi16>,16 ; N high half      <-- HOLE B (immediate)
    // loop=4:
    //  [4] CMP  x2, x3              ; i ? N            (loop-branch stencil)
    //  [5] B.GE done                ; exit if i>=N      <- intra branch hole
    //  [6] ADD  x1, x1, x2          ; acc += i          (integer-add stencil)
    //  [7] ADD  x2, x2, #1          ; i += 1
    //  [8] B    loop                ; back-edge         <- back-edge branch hole
    // done=9:
    //  [9] ADD  x0, x1, XZR         ; result = acc
    // [10] RET
    uint32_t code[16];
    size_t k = 0;
    code[k++] = MOVZ_X(1, 0);                          // [0]
    code[k++] = MOVZ_X(2, 0);                          // [1]
    size_t holeA = k;
    code[k++] = MOVZ_X(3, HOLE_SENTINEL);              // [2] HOLE A
    size_t holeB = k;
    code[k++] = MOVK_X_LSL16(3, HOLE_SENTINEL);        // [3] HOLE B
    size_t loop = k;                                   // = 4
    code[k++] = CMP_X_REG(2, 3);                       // [4]
    size_t bge = k;
    code[k++] = 0;                                     // [5] B.GE done (fixed below)
    code[k++] = ADD_X(1, 1, 2);                        // [6]
    code[k++] = ADD_X_IMM(2, 2, 1);                    // [7]
    size_t back = k;
    code[k++] = 0;                                     // [8] B loop (fixed below)
    size_t done = k;                                   // = 9
    code[k++] = ADD_X(0, 1, XZR);                      // [9]
    code[k++] = RET_X30;                               // [10]

    // Resolve the two intra-function branch holes (PC-relative, in insns).
    code[bge]  = BCOND(COND_GE, (int32_t)(done - bge));
    code[back] = B_UNCOND((int32_t)(loop - back));     // negative -> back-edge

    const size_t code_bytes = k * 4;

    // -- (2) Allocate the W^X JIT buffer (MAP_JIT mandatory on Apple Silicon).
    size_t page = (size_t)getpagesize();
    size_t map_len = (code_bytes + page - 1) & ~(page - 1);
    void *mem = mmap(NULL, map_len,
                     PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap(MAP_JIT)"); return 2; }
    printf("[poc] mmap MAP_JIT ok: %p (%zu bytes, page=%zu)\n",
           mem, map_len, page);

    // -- (3) Enter WRITE mode, COPY stencils, PATCH the immediate hole, re-protect.
    pthread_jit_write_protect_np(0);                   // 0 = writable (not exec)

    memcpy(mem, code, code_bytes);                     // the COPY

    uint32_t *p = (uint32_t *)mem;
    int sentinel_ok =
        (p[holeA] == MOVZ_X(3, HOLE_SENTINEL)) &&
        (p[holeB] == MOVK_X_LSL16(3, HOLE_SENTINEL));
    uint16_t n_lo = (uint16_t)(N & 0xFFFFu);
    uint16_t n_hi = (uint16_t)((N >> 16) & 0xFFFFu);
    p[holeA] = MOVZ_X(3, n_lo);                        // PATCH hole A
    p[holeB] = MOVK_X_LSL16(3, n_hi);                  // PATCH hole B

    pthread_jit_write_protect_np(1);                   // 1 = executable

    // -- (4) i-cache flush (mandatory on arm64 after writing code), then call.
    sys_icache_invalidate(mem, code_bytes);

    printf("[poc] hole sentinel present before patch: %s\n",
           sentinel_ok ? "yes" : "NO (encoding mismatch)");
    printf("[poc] patched N=%llu (lo=0x%04x hi=0x%04x)\n",
           (unsigned long long)N, n_lo, n_hi);

    typedef uint64_t (*sumfn)(void);
    uint64_t got = ((sumfn)mem)();                     // EXECUTE jit'd code

    printf("[poc] jit sum(0..%llu-1) = %llu\n",
           (unsigned long long)N, (unsigned long long)got);
    printf("[poc] expected           = %llu\n",
           (unsigned long long)EXPECTED);

    int ok = sentinel_ok && (got == EXPECTED);
    printf("[poc] %s\n", ok ? "PASS" : "FAIL");

    munmap(mem, map_len);
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
// How this maps onto the REAL zjs stencil pipeline (CPython Tools/jit/ model)
// ---------------------------------------------------------------------------
// This POC hand-encodes machine code so the mechanism is self-evident. The
// production path replaces hand-encoding with BUILD-TIME extraction:
//
//   1. Author each opcode body as a function in a stencil TU (in zc), e.g.
//        fn zjs_stencil_Add(regs: ZjsValue*, a: u8, b: u8, c: u8) { ... }
//      with the holes (immediates, branch targets, runtime-helper addresses)
//      expressed as `extern` placeholder symbols.
//   2. Transpile with `zc`, then compile that C with clang -O3 -c to a
//      relocatable object (.o), one per target arch (arm64, x86-64). No link.
//   3. A build step (Python, like CPython _stencils.py / jit.py) reads the .o:
//      pulls each function's .text bytes (the stencil body) and its relocation
//      records (the "holes" — offset + kind + target symbol). It emits a
//      generated C/zc header:
//        static const uint8_t STENCIL_Add[]      = { 0x.. };
//        static const Hole    STENCIL_Add_holes[]= {{off, kind, sym}, ...};
//   4. At runtime the JIT does exactly steps (2)-(4) of this POC: mmap MAP_JIT,
//      memcpy STENCIL_<op> per bytecode instruction, apply each hole (splice
//      immediate / fix up branch to the next stencil / store helper address),
//      toggle write-protect, icache-flush, execute.
//
// zc wrinkle: zc transpiles to C, so the stencil TU goes zc -> C -> clang -O3,
// the SAME path as the interpreter op-bodies — guaranteeing a JIT'd Add does
// exactly what the interpreted Add does (the design study's conformance win).
// ---------------------------------------------------------------------------
