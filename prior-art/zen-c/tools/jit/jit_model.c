// jit_model.c — models what a zjs *baseline copy-and-patch* JIT realistically
// emits for the int_loop body, to estimate the ACHIEVABLE ceiling (as opposed
// to native_ref.c's full-regalloc native ceiling, which a no-regalloc baseline
// JIT can never reach).
//
// The design study pins the frame model: JIT'd code keeps every virtual
// register in the SAME stack-frame slot the interpreter uses (no register
// allocation). So values stay NaN-boxed in a memory array; each op loads the
// boxed operands from frame slots, does an inline int32 tag-check + unbox,
// the arithmetic, reboxes, and stores back. What the JIT REMOVES vs the
// interpreter is: the dispatch indirect branch, the operand (a/b/c) decode,
// and the cold guard ladder in Op::Add (object/string/bigint/symbol checks).
//
// This file hand-writes that realistic emitted shape in C so clang -O3
// compiles it the same way the copy-and-patch stencils would be compiled.
// The gap between this and native_ref's int_loop_real is the cost of the
// NaN-box memory-frame discipline the baseline JIT is contractually keeping.
//
// Build: clang -O3 -o /tmp/jit_model tools/jit_model.c
// Run:   /tmp/jit_model [iters]

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

// --- minimal NaN-box mirror of zjs's ZjsValue int32 representation ---------
// zjs (value.zc): int32 values are a quiet-NaN box with a tag in the high bits
// and the i32 payload in the low 32. We replicate just enough to pay the same
// tag-check + unbox + rebox cost the JIT'd Add would pay. (Exact bit layout is
// irrelevant to timing; what matters is: read u64 from memory, mask+compare
// tag, sign-extend low32, add, rebox to u64, write back to memory.)
typedef uint64_t Value;
#define QNAN      0x7ff8000000000000ull
#define TAG_INT32 0x0001000000000000ull        // arbitrary distinct tag bit
#define INT32_BOX(i) (QNAN | TAG_INT32 | (uint32_t)(int32_t)(i))
#define IS_INT32(v)  (((v) & (QNAN | TAG_INT32)) == (QNAN | TAG_INT32))
#define AS_INT32(v)  ((int32_t)(uint32_t)((v) & 0xffffffffull))

static int64_t opaque_i64(int64_t v){ __asm__ volatile("":"+r"(v)); return v; }

// The "frame": values live in a memory array, exactly like the interpreter's
// register file that the baseline JIT shares. We force them through memory
// (volatile-ish via the opaque barrier on the loop) so clang can't hoist the
// whole thing into registers + closed-form it — matching the JIT, which MUST
// keep them in the shared frame for free deopt/GC.
int main(int argc, char **argv) {
    int64_t n = (argc >= 2) ? strtoll(argv[1], NULL, 10) : 10000000;

    // frame slots: [0]=sum, [1]=i, [2]=n
    static Value frame[4];
    double best = 1e18;
    int64_t result = 0;
    for (int rep = 0; rep < 5; rep++) {
        frame[0] = INT32_BOX(0);            // sum
        frame[1] = INT32_BOX(0);            // i
        // n won't fit int32 if huge; clamp the model to int32 range loop count
        int64_t iters = n;
        double t0 = now_ms();
        // This is the JIT'd loop body: NO dispatch, NO decode, but full
        // NaN-box load/tag-check/unbox/add/rebox/store through the frame.
        for (int64_t c = 0; c < iters; c++) {
            Value sv = frame[0];
            Value iv = frame[1];
            // inline int32 guard (the IC-style guard the JIT emits inline)
            if (IS_INT32(sv) & IS_INT32(iv)) {
                int64_t s = (int64_t)AS_INT32(sv) + (int64_t)AS_INT32(iv);
                // overflow check mirrors zjs_arith_add
                if (s >= INT32_MIN && s <= INT32_MAX) frame[0] = INT32_BOX((int32_t)s);
                else frame[0] = INT32_BOX((int32_t)s); // model: stay boxed (sum overflows i32 in this bench, but cost is the same shape)
            }
            // i = i + 1
            Value iv2 = frame[1];
            if (IS_INT32(iv2)) frame[1] = INT32_BOX(AS_INT32(iv2) + 1);
            // keep frame in memory across iterations
            __asm__ volatile("" :: "r"(frame) : "memory");
        }
        double t1 = now_ms();
        if (t1 - t0 < best) best = t1 - t0;
        result = (int64_t)opaque_i64((int64_t)AS_INT32(frame[0]));
    }
    printf("jit_model int_loop n=%lld real_ms=%.3f (frame[0] low32=%lld)\n",
           (long long)n, best, (long long)result);
    return 0;
}
