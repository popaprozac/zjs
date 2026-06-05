// loop_test.c — J3 validation: stitch a real LOOP from extracted stencils.
//
// Proves the copy-and-patch stitcher scales to the int_loop shape — the J4
// target — with operand holes (GOT), fall-through continuations, a forward
// conditional branch, and a BACK-EDGE, computing sum(0..N-1) and checking it
// against the closed form. Two-pass: place stencils + record each instruction's
// code offset, then patch operands + branches to those offsets.
//
//   make jit-stencils jit-stencils-header
//   clang -O2 -Ibuild -o /tmp/loop_test tools/jit/loop_test.c && /tmp/loop_test
//
// arm64-apple-darwin. Values are raw int64 in .bits here (this validates the
// STITCHING; conformance-faithful NaN-box stencils are the engine step).
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>

#include "jit_stencils_arm64.h"

typedef struct { uint64_t bits; } ZjsValue;

static const JitStencil *find_stencil(const char *name) {
    for (int i = 0; i < JIT_STENCIL_COUNT; i++)
        if (!strcmp(JIT_STENCILS[i].name, name)) return &JIT_STENCILS[i];
    fprintf(stderr, "loop_test: missing stencil %s\n", name);
    return 0;
}

static void patch_adrp(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t d = ((int64_t)(target & ~0xFFFULL) - (int64_t)(pc & ~0xFFFULL)) >> 12;
    uint32_t v = *insn;
    v &= ~((3u << 29) | (0x7FFFFu << 5));
    v |= ((uint32_t)(d & 3) << 29) | ((uint32_t)((d >> 2) & 0x7FFFF) << 5);
    *insn = v;
}
static void patch_ldr_off(uint32_t *insn, uint64_t target) {
    uint32_t v = *insn;
    v &= ~(0xFFFu << 10);
    v |= ((uint32_t)((target & 0xFFF) >> 3) << 10);
    *insn = v;
}
static void patch_b(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t off = ((int64_t)target - (int64_t)pc) >> 2;
    *insn = 0x14000000u | ((uint32_t)off & 0x3FFFFFFu);
}

// One bytecode instruction in the toy program.
typedef struct {
    const char *op;          // stencil name
    int ra, rb, rc;          // operand register indices (-1 = unused)
    int64_t imm;             // immediate
    int target;              // branch destination insn index (-1 = none)
} Insn;

int main(void) {
    const int64_t N = 1000000;
    const uint64_t EXPECTED = (uint64_t)(N * (N - 1) / 2);

    // regs: r0=acc r1=i r2=N r3=cond.   sum(0..N-1) into r0.
    enum { ACC = 0, I = 1, NN = 2, COND = 3 };
    enum { LOOP = 3, DONE = 8 };
    Insn prog[] = {
        /*0*/ { "LoadConst", ACC,  -1, -1, 0, -1 },
        /*1*/ { "LoadConst", I,    -1, -1, 0, -1 },
        /*2*/ { "LoadConst", NN,   -1, -1, N, -1 },
        /*3*/ { "CmpLt",     COND, I,  NN, 0, -1 },          // cond = i < N
        /*4*/ { "JmpIfFalse", COND, -1, -1, 0, DONE },        // if !cond -> done
        /*5*/ { "Add",       ACC,  ACC, I, 0, -1 },          // acc += i
        /*6*/ { "AddImm",    I,    I,  -1, 1, -1 },           // i += 1
        /*7*/ { "Jmp",       -1,   -1, -1, 0, LOOP },         // -> loop
        /*8*/ { "Return",    -1,   -1, -1, 0, -1 },
    };
    int n = sizeof(prog) / sizeof(prog[0]);

    // --- Pass 1: lay out stencils, record each insn's code offset.
    uint32_t off[64];
    size_t code_len = 0;
    for (int i = 0; i < n; i++) {
        const JitStencil *s = find_stencil(prog[i].op);
        if (!s) return 2;
        off[i] = (uint32_t)code_len;
        code_len += s->code_len;
    }
    size_t got_off = (code_len + 7) & ~7ULL;
    size_t max_slots = (size_t)n * 4;
    size_t total = got_off + max_slots * 8;

    size_t page = (size_t)getpagesize();
    size_t map_len = (total + page - 1) & ~(page - 1);
    void *mem = mmap(NULL, map_len, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap(MAP_JIT)"); return 2; }
    uint8_t *base = (uint8_t *)mem;
    uint64_t *got = (uint64_t *)(base + got_off);

    pthread_jit_write_protect_np(0);

    // Copy stencil bodies in.
    for (int i = 0; i < n; i++) {
        const JitStencil *s = find_stencil(prog[i].op);
        memcpy(base + off[i], s->code, s->code_len);
    }

    // --- Pass 2: patch operand holes (via a per-insn GOT) + branches.
    size_t next_slot = 0;
    for (int i = 0; i < n; i++) {
        const JitStencil *s = find_stencil(prog[i].op);
        // Per-insn symbol -> got slot (alloc on first use within this insn).
        const char *slot_sym[4] = {0,0,0,0};
        uint64_t   *slot_addr[4] = {0,0,0,0};
        int        nslot = 0;
        for (uint32_t h = 0; h < s->nholes; h++) {
            const JitHole *hole = &s->holes[h];
            uint32_t *insn = (uint32_t *)(base + off[i] + hole->offset);
            uint64_t  pc   = (uint64_t)insn;
            if (hole->kind == JIT_HOLE_BRANCH26) {
                int dst = (!strcmp(hole->sym, "__JIT_TARGET")) ? prog[i].target : i + 1;
                patch_b(insn, pc, (uint64_t)(base + off[dst]));
                continue;
            }
            // GOT operand hole: find/alloc this insn's slot for the symbol.
            int si = -1;
            for (int k = 0; k < nslot; k++) if (slot_sym[k] == hole->sym) { si = k; break; }
            if (si < 0) {
                si = nslot++;
                slot_sym[si]  = hole->sym;
                slot_addr[si] = &got[next_slot++];
                uint64_t val =
                    !strcmp(hole->sym, "__JIT_RA")    ? (uint64_t)prog[i].ra  :
                    !strcmp(hole->sym, "__JIT_RB")    ? (uint64_t)prog[i].rb  :
                    !strcmp(hole->sym, "__JIT_RC")    ? (uint64_t)prog[i].rc  :
                    !strcmp(hole->sym, "__JIT_IMM64") ? (uint64_t)prog[i].imm : 0;
                *slot_addr[si] = val;
            }
            uint64_t slot = (uint64_t)slot_addr[si];
            if (hole->kind == JIT_HOLE_GOT_PAGE21)      patch_adrp(insn, pc, slot);
            else if (hole->kind == JIT_HOLE_GOT_PAGEOFF12) patch_ldr_off(insn, slot);
        }
    }

    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(mem, total);

    ZjsValue regs[16];
    memset(regs, 0, sizeof(regs));
    typedef void (*entry)(ZjsValue *);
    ((entry)mem)(regs);

    int ok = (regs[ACC].bits == EXPECTED);
    printf("[loop] jit sum(0..%lld-1) = %llu\n", (long long)N,
           (unsigned long long)regs[ACC].bits);
    printf("[loop] expected          = %llu\n", (unsigned long long)EXPECTED);
    printf("[loop] %s\n", ok ? "PASS" : "FAIL");

    munmap(mem, map_len);
    return ok ? 0 : 1;
}
