// Platform-native child-process spawn-and-capture.
//
// Mirrors http_native.h's pattern: one C ABI entry point, implemented
// per-platform (process_posix.c on Apple/Linux/iOS, process_windows.c
// on Windows). node_child_process.zc only ever calls this signature.
//
// Semantics (shared contract):
//   - Launches `file` with `argv` (NULL-terminated, argv[0] = file),
//     optionally chdir'd to `cwd`, writes `in_data` to its stdin, then
//     drains stdout/stderr to completion and reaps the child.
//   - Returns 0 when the child ran (regardless of its exit status);
//     -1 when the spawn itself failed, with an errno-domain code in
//     *err_no_out (Windows maps GetLastError → nearest errno).
//   - *status_out  = exit code (>= 0), or -1 if signal-killed.
//   - *signal_out  = terminating signal number (POSIX), 0 otherwise.
//     Windows children always report signal 0.
//   - *out_buf/*err_buf are malloc'd (may be NULL when empty); caller
//     frees.

#ifndef ZJS_PROCESS_NATIVE_H
#define ZJS_PROCESS_NATIVE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int zjs_process_spawn_capture(const char* file, char* const* argv,
                              const char* cwd,
                              const char* in_data, size_t in_len,
                              char** out_buf_p, size_t* out_len_p,
                              char** err_buf_p, size_t* err_len_p,
                              int* status_out, int* signal_out,
                              int* err_no_out);

#ifdef __cplusplus
}
#endif

#endif // ZJS_PROCESS_NATIVE_H
