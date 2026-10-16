// stitch_test.c — pipeline GO/NO-GO for the zjs JIT (J2 validation).
//
// Proves the FULL copy-and-patch path end to end using EXTRACTED stencils
// (not hand-encoded): compile tools/jit/stencils.c -> extract_stencils.py ->
// build/jit_stencils_<arch>.h -> stitch under W^X with a synthetic GOT -> run.
//
// It stitches a one-instruction program  `LoadConst regs[RA] = IMM64`  followed
// by a RET, patching the GOT-indirect operand holes (the J1 finding: arm64
// materializes holes via adrp@GOTPAGE/ldr@GOTPAGEOFF) and the BRANCH26
// continuation, then calls it on a real frame and checks regs[RA].bits == IMM64.
//
// Build & run:
//   make jit-stencils
//   python3 tools/jit/extract_stencils.py build/jit_stencils-arm64.o build/jit_stencils_arm64.h
//   clang -O2 -Ibuild -o /tmp/stitch_test tools/jit/stitch_test.c && /tmp/stitch_test
//
// arm64-apple-darwin only (matches the J1/J2 substrate).
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>

#include "jit_stencils_arm64.h"   // generated: JIT_STENCILS[], JitStencil, JitHole

typedef struct { uint64_t bits; } ZjsValue;

static const JitStencil *find_stencil(const char *name) {
    for (int i = 0; i < JIT_STENCIL_COUNT; i++)
        if (!strcmp(JIT_STENCILS[i].name, name)) return &JIT_STENCILS[i];
    return 0;
}

// --- arm64 instruction patchers (operate on the live JIT buffer) ------------
// ADRP Xd, page(target): imm21 = (page(target) - page(pc)) >> 12, split immlo/immhi.
static void patch_adrp(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t d = ((int64_t)(target & ~0xFFFULL) - (int64_t)(pc & ~0xFFFULL)) >> 12;
    uint32_t immlo = (uint32_t)(d & 3), immhi = (uint32_t)((d >> 2) & 0x7FFFF);
    uint32_t v = *insn;
    v &= ~((3u << 29) | (0x7FFFFu << 5));
    v |= (immlo << 29) | (immhi << 5);
    *insn = v;
}
// LDR Xt, [Xn, #imm12]: imm12 = (target & 0xFFF) >> 3 (scaled for a 64-bit load).
static void patch_ldr_off(uint32_t *insn, uint64_t target) {
    uint32_t imm12 = (uint32_t)((target & 0xFFF) >> 3);
    uint32_t v = *insn;
    v &= ~(0xFFFu << 10);
    v |= (imm12 << 10);
    *insn = v;
}
// B label: imm26 = (target - pc) >> 2.
static void patch_b(uint32_t *insn, uint64_t pc, uint64_t target) {
    int64_t off = ((int64_t)target - (int64_t)pc) >> 2;
    *insn = 0x14000000u | ((uint32_t)off & 0x3FFFFFFu);
}

#define RET_X30 0xD65F03C0u

int main(void) {
    const uint64_t RA    = 2;                       // dest frame slot
    const uint64_t IMM64 = 0x123456789ABCDEF0ULL;   // sentinel "NaN-boxed value"

    const JitStencil *lc = find_stencil("LoadConst");
    if (!lc) { fprintf(stderr, "no LoadConst stencil\n"); return 2; }

    // Layout in one W^X page:  [stencil code][RET]  ...8-align...  [GOT slots]
    // GOT slot order: [0]=value for __JIT_RA, [1]=value for __JIT_IMM64.
    size_t code_len = lc->code_len;
    size_t ret_off  = code_len;
    size_t after    = ret_off + 4;
    size_t got_off  = (after + 7) & ~7ULL;     // 8-byte align the GOT region
    size_t n_got    = 2;
    size_t total    = got_off + n_got * 8;

    size_t page = (size_t)getpagesize();
    size_t map_len = (total + page - 1) & ~(page - 1);
    void *mem = mmap(NULL, map_len, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap(MAP_JIT)"); return 2; }
    uint8_t *base = (uint8_t *)mem;

    pthread_jit_write_protect_np(0);              // writable

    memcpy(base, lc->code, code_len);             // COPY the stencil
    *(uint32_t *)(base + ret_off) = RET_X30;      // terminating RET

    uint64_t *got = (uint64_t *)(base + got_off);
    got[0] = RA;                                  // __JIT_RA  -> index 2
    got[1] = IMM64;                               // __JIT_IMM64 -> the value
    uint64_t ra_slot  = (uint64_t)(base + got_off + 0);
    uint64_t imm_slot = (uint64_t)(base + got_off + 8);
    uint64_t ret_addr = (uint64_t)(base + ret_off);

    // PATCH each hole. The GOT page/pageoff relocs come as same-symbol pairs at
    // consecutive offsets (adrp then ldr); BRANCH26 is the continuation.
    for (uint32_t h = 0; h < lc->nholes; h++) {
        const JitHole *hole = &lc->holes[h];
        uint32_t *insn = (uint32_t *)(base + hole->offset);
        uint64_t insn_pc = (uint64_t)insn;
        if (hole->kind == JIT_HOLE_GOT_PAGE21) {
            uint64_t slot = !strcmp(hole->sym, "__JIT_RA") ? ra_slot : imm_slot;
            patch_adrp(insn, insn_pc, slot);
        } else if (hole->kind == JIT_HOLE_GOT_PAGEOFF12) {
            uint64_t slot = !strcmp(hole->sym, "__JIT_RA") ? ra_slot : imm_slot;
            patch_ldr_off(insn, slot);
        } else if (hole->kind == JIT_HOLE_BRANCH26) {
            patch_b(insn, insn_pc, ret_addr);     // continuation -> RET
        }
    }

    pthread_jit_write_protect_np(1);              // executable
    sys_icache_invalidate(mem, total);

    ZjsValue regs[16];
    memset(regs, 0, sizeof(regs));
    typedef void (*stencilfn)(ZjsValue *);
    ((stencilfn)mem)(regs);                       // EXECUTE the stitched code

    int ok = (regs[RA].bits == IMM64);
    printf("[stitch] regs[%llu].bits = 0x%016llx\n", (unsigned long long)RA,
           (unsigned long long)regs[RA].bits);
    printf("[stitch] expected        = 0x%016llx\n", (unsigned long long)IMM64);
    printf("[stitch] %s\n", ok ? "PASS" : "FAIL");

    munmap(mem, map_len);
    return ok ? 0 : 1;
}
