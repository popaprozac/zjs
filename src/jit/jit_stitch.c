// src/jit/jit_stitch.c — zjs JIT copy-and-patch stitcher (engine side).
//
// Compiled into the engine ONLY when ZJS_JIT is set (Makefile appends this
// source + -DZJS_JIT + -Ibuild to the `zc build`); the default and iOS builds
// never see it. The interpreter calls in through the small extern interface
// below, all under `#ifdef ZJS_JIT` on the zc side.
//
// This file is the machine-level half (mmap MAP_JIT, copy stencils, patch the
// GOT-indirect operand holes + BRANCH26 continuations); it includes the
// build-generated stencil table. The zc side (the interpreter) supplies a
// decoded instruction list and reads back the frame. See docs/jit-impl-notes.md.

#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>

#include "jit_stencils_arm64.h"   // generated: JIT_STENCILS[], JitStencil, JitHole

typedef struct { uint64_t bits; } JitValue;

static const JitStencil *jit_find_stencil(const char *name) {
    for (int i = 0; i < JIT_STENCIL_COUNT; i++)
        if (!strcmp(JIT_STENCILS[i].name, name)) return &JIT_STENCILS[i];
    return 0;
}

// --- arm64 patchers ----------------------------------------------------------
static void jit_patch_adrp(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t d = ((int64_t)(target & ~0xFFFULL) - (int64_t)(pc & ~0xFFFULL)) >> 12;
    uint32_t v = *insn;
    v &= ~((3u << 29) | (0x7FFFFu << 5));
    v |= ((uint32_t)(d & 3) << 29) | ((uint32_t)((d >> 2) & 0x7FFFF) << 5);
    *insn = v;
}
static void jit_patch_ldr_off(uint32_t *insn, uint64_t target) {
    uint32_t v = *insn;
    v &= ~(0xFFFu << 10);
    v |= ((uint32_t)((target & 0xFFF) >> 3) << 10);
    *insn = v;
}
static void jit_patch_b(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t off = ((int64_t)target - (int64_t)pc) >> 2;
    *insn = 0x14000000u | ((uint32_t)off & 0x3FFFFFFu);
}

// A decoded instruction handed to the stitcher (the zc side builds these).
typedef struct {
    const char *op;        // stencil name (must exist in JIT_STENCILS)
    int ra, rb, rc;        // operand register indices (-1 = unused)
    int64_t imm;           // immediate operand
    int target;            // branch destination instruction index (-1 = none)
} JitInsn;

// Two-pass stitch of `prog` into a W^X region; returns the entry function
// pointer (called as `void entry(JitValue *regs)`), or NULL on failure. The
// region is leaked for now (per-Function* cache + free is a later step).
static void *jit_stitch(const JitInsn *prog, int n) {
    uint32_t off[256];
    size_t code_len = 0;
    if (n > 256) return 0;
    for (int i = 0; i < n; i++) {
        const JitStencil *s = jit_find_stencil(prog[i].op);
        if (!s) return 0;
        off[i] = (uint32_t)code_len;
        code_len += s->code_len;
    }
    size_t got_off = (code_len + 7) & ~7ULL;
    size_t total   = got_off + (size_t)n * 4 * 8;
    size_t page    = (size_t)getpagesize();
    size_t map_len = (total + page - 1) & ~(page - 1);
    void *mem = mmap(NULL, map_len, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) return 0;
    uint8_t *base = (uint8_t *)mem;
    uint64_t *got = (uint64_t *)(base + got_off);

    pthread_jit_write_protect_np(0);
    for (int i = 0; i < n; i++) {
        const JitStencil *s = jit_find_stencil(prog[i].op);
        memcpy(base + off[i], s->code, s->code_len);
    }
    size_t next_slot = 0;
    for (int i = 0; i < n; i++) {
        const JitStencil *s = jit_find_stencil(prog[i].op);
        const char *slot_sym[4]  = {0, 0, 0, 0};
        uint64_t   *slot_addr[4] = {0, 0, 0, 0};
        int         nslot = 0;
        for (uint32_t h = 0; h < s->nholes; h++) {
            const JitHole *hole = &s->holes[h];
            uint32_t *insn = (uint32_t *)(base + off[i] + hole->offset);
            uint64_t  pc   = (uint64_t)insn;
            if (hole->kind == JIT_HOLE_BRANCH26) {
                int dst = !strcmp(hole->sym, "__JIT_TARGET") ? prog[i].target : i + 1;
                jit_patch_b(insn, pc, (uint64_t)(base + off[dst]));
                continue;
            }
            int si = -1;
            for (int k = 0; k < nslot; k++) if (slot_sym[k] == hole->sym) { si = k; break; }
            if (si < 0) {
                si = nslot++;
                slot_sym[si]  = hole->sym;
                slot_addr[si] = &got[next_slot++];
                *slot_addr[si] =
                    !strcmp(hole->sym, "__JIT_RA")    ? (uint64_t)prog[i].ra  :
                    !strcmp(hole->sym, "__JIT_RB")    ? (uint64_t)prog[i].rb  :
                    !strcmp(hole->sym, "__JIT_RC")    ? (uint64_t)prog[i].rc  :
                    !strcmp(hole->sym, "__JIT_IMM64") ? (uint64_t)prog[i].imm : 0;
            }
            uint64_t slot = (uint64_t)slot_addr[si];
            if (hole->kind == JIT_HOLE_GOT_PAGE21)         jit_patch_adrp(insn, pc, slot);
            else if (hole->kind == JIT_HOLE_GOT_PAGEOFF12) jit_patch_ldr_off(insn, slot);
        }
    }
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(mem, total);
    return mem;
}

// ---- extern interface called from the zc side (interpreter) ----------------

// Compile a decoded instruction list into an executable region. The zc side
// (which can read Function*/Inst/Op natively) builds `prog` — a layout-matched
// array of JitInsn — and runs the returned pointer on its frame. NULL = bail.
void *jit_compile(const JitInsn *prog, int n) {
    return jit_stitch(prog, n);
}

// NaN-box mirror (must match value.zc + stencils.c) for building/checking the
// faithful self-test values.
#define JIT_NUMBER_TAG  0xfffe000000000000ULL
#define JIT_DBL_OFFSET  0x0002000000000000ULL   /* 1 << 49 */
static uint64_t jit_box_int32(int32_t i) { return JIT_NUMBER_TAG | (uint32_t)i; }
static uint64_t jit_box_double(double d) {
    union { double d; uint64_t u; } x; x.d = d; return x.u + JIT_DBL_OFFSET;
}

// Self-test: JIT the int_loop body and confirm sum(0..N-1). Returns 1 on PASS.
// Proves the engine binary contains + runs the JIT stitcher end to end — now
// with the FAITHFUL NaN-box arithmetic stencils (J4): values are real boxed
// cells, and because sum(0..N-1) overflows int32 partway, this exercises the
// int32 fast path, the int32→double overflow promotion, AND the double-add
// path, plus the boolean loop condition and the back-edge. EXPECTED is the
// boxed double the interpreter's zjs_arith_add would produce.
int jit_selftest_loop(void) {
    const int64_t N = 1000000;
    const uint64_t EXPECTED = jit_box_double((double)(N * (N - 1) / 2));
    enum { ACC = 0, I = 1, NN = 2, COND = 3, LOOP = 3, DONE = 8 };
    JitInsn prog[] = {
        { "LoadConst", ACC, -1, -1, (int64_t)jit_box_int32(0), -1 },
        { "LoadConst", I,   -1, -1, (int64_t)jit_box_int32(0), -1 },
        { "LoadConst", NN,  -1, -1, (int64_t)jit_box_int32((int32_t)N), -1 },
        { "CmpLt", COND, I, NN, 0, -1 },
        { "JmpIfFalse", COND, -1, -1, 0, DONE },
        { "Add", ACC, ACC, I, 0, -1 },
        { "AddImm", I, I, -1, (int64_t)jit_box_int32(1), -1 },
        { "Jmp", -1, -1, -1, 0, LOOP },
        { "Return", -1, -1, -1, 0, -1 },
    };
    void *code = jit_stitch(prog, (int)(sizeof(prog) / sizeof(prog[0])));
    if (!code) return 0;
    JitValue regs[16];
    memset(regs, 0, sizeof(regs));
    int deopt = 0;
    ((void (*)(JitValue *, int *))code)(regs, &deopt);
    if (deopt) return 0;
    return regs[ACC].bits == EXPECTED ? 1 : 0;
}
