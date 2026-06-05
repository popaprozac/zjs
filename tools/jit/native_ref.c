// native_ref.c — clang -O3 reference loops mirroring the zjs JS microbenches.
// Bounds the dispatch-elimination ceiling for the Phase-1 JIT spike: the ratio
// (zjs interpreter time / native time) on the SAME loop is the optimistic best
// case for a baseline JIT that only removes per-op dispatch + operand decode.
//
// IMPORTANT honesty note: clang -O3 will algebraically collapse sum(0..n-1)
// to the closed form n*(n-1)/2 (zero loop iterations). A JIT can NEVER do that
// — it must execute every iteration. So we provide TWO native baselines:
//
//   *_folded   : whatever -O3 does freely (may collapse the loop) — NOT a fair
//                JIT ceiling, reported only to show how aggressive -O3 is.
//   *_real     : the loop forced to actually run N iterations via an opaque
//                per-iteration barrier, so it does the real integer-add work
//                with NO interpreter dispatch. THIS is the honest ceiling.
//
// Build:  clang -O3 -o /tmp/native_ref tools/native_ref.c
// Run:    /tmp/native_ref <int_loop|double_loop|fib> [iters]
//
// Times the loop body only (CLOCK_MONOTONIC), matching the in-JS Date.now()
// timing used on the zjs side (both exclude process startup).

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

// Opaque identity barrier: clang can't see through inline asm, so it can't
// prove the loop has a closed form. The barrier itself is a no-op (just keeps
// the value live in a register), so the per-iteration cost is the genuine
// arithmetic + loop overhead — exactly what a baseline JIT would emit.
static inline int64_t opaque_i64(int64_t v) {
    __asm__ volatile("" : "+r"(v));
    return v;
}
static inline double opaque_f64(double v) {
    __asm__ volatile("" : "+w"(v));   // arm64 FP/SIMD register constraint
    return v;
}

// --- folded: -O3 free to do whatever (may collapse to closed form) ---
__attribute__((noinline))
static int64_t int_loop_folded(int64_t n) {
    int64_t sum = 0;
    for (int64_t i = 0; i < n; i = i + 1) sum = sum + i;
    return sum;
}

// --- real: loop forced to execute N iterations, no dispatch ---
__attribute__((noinline))
static int64_t int_loop_real(int64_t n) {
    int64_t sum = 0;
    for (int64_t i = 0; i < n; i = i + 1) {
        sum = opaque_i64(sum + i);   // barrier defeats closed-form folding
    }
    return sum;
}

__attribute__((noinline))
static double double_loop_folded(int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i = i + 1) sum = sum + 1.5;
    return sum;
}
__attribute__((noinline))
static double double_loop_real(int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i = i + 1) sum = opaque_f64(sum + 1.5);
    return sum;
}

// fib is naturally call-bound and not closed-form-collapsible; one version.
__attribute__((noinline))
static int64_t fib(int64_t n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

static double best_of(int reps, double (*run)(int64_t, void*), int64_t n, void *out) {
    double best = 1e18;
    for (int r = 0; r < reps; r++) {
        double t0 = now_ms();
        run(n, out);
        double t1 = now_ms();
        if (t1 - t0 < best) best = t1 - t0;
    }
    return best;
}

static double run_int_folded(int64_t n, void *out) { *(int64_t*)out = int_loop_folded(n); return 0; }
static double run_int_real(int64_t n, void *out)   { *(int64_t*)out = int_loop_real(n);   return 0; }
static double run_dbl_folded(int64_t n, void *out) { *(double*)out  = double_loop_folded(n); return 0; }
static double run_dbl_real(int64_t n, void *out)   { *(double*)out  = double_loop_real(n);   return 0; }
static double run_fib(int64_t n, void *out)        { *(int64_t*)out = fib(opaque_i64(n)); return 0; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <int_loop|double_loop|fib> [iters]\n", argv[0]); return 1; }
    const char *which = argv[1];
    int64_t iters = (argc >= 3) ? strtoll(argv[2], NULL, 10) : 0;
    const int REPS = 5;

    if (strcmp(which, "int_loop") == 0) {
        int64_t n = iters ? iters : 10000000;
        int64_t rf, rr; double i64;
        double bf = best_of(REPS, run_int_folded, n, &rf);
        double br = best_of(REPS, run_int_real,   n, &rr);
        (void)i64;
        printf("int_loop n=%lld folded_ms=%.3f real_ms=%.3f result_folded=%lld result_real=%lld\n",
               (long long)n, bf, br, (long long)rf, (long long)rr);
    } else if (strcmp(which, "double_loop") == 0) {
        int64_t n = iters ? iters : 500000;
        double rf, rr;
        double bf = best_of(REPS, run_dbl_folded, n, &rf);
        double br = best_of(REPS, run_dbl_real,   n, &rr);
        printf("double_loop n=%lld folded_ms=%.3f real_ms=%.3f result_folded=%.1f result_real=%.1f\n",
               (long long)n, bf, br, rf, rr);
    } else if (strcmp(which, "fib") == 0) {
        int64_t n = iters ? iters : 32;
        int64_t r;
        double b = best_of(REPS, run_fib, n, &r);
        printf("fib n=%lld real_ms=%.3f result=%lld\n", (long long)n, b, (long long)r);
    } else {
        fprintf(stderr, "unknown bench: %s\n", which);
        return 1;
    }
    return 0;
}
