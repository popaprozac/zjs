// Windows implementation of process_native.h — CreateProcess +
// anonymous pipes.
//
// Shape mirrors process_posix.c: spawn, feed stdin, drain stdout +
// stderr to malloc'd buffers, reap, report exit status. Differences
// forced by Win32:
//   - No fork/exec: a single CreateProcessA with a quoted command line
//     (argv joined per the MSVCRT quoting rules) and PATH search
//     (lpApplicationName = NULL also appends .exe).
//   - No poll() on pipes: drain loop uses PeekNamedPipe + ReadFile,
//     sleeping briefly when neither pipe has data and the child is
//     still running.
//   - No signals: *signal_out is always 0; exit code comes from
//     GetExitCodeProcess.

#ifdef _WIN32

#include "process_native.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>

// Grow-by-doubling append. cap = 0 means uninitialized.
static int buf_append(char** buf, size_t* len, size_t* cap,
                      const char* src, size_t n) {
    if (n == 0) return 1;
    size_t need = *len + n;
    if (need > *cap) {
        size_t new_cap = (*cap == 0) ? 4096 : *cap * 2;
        while (new_cap < need) new_cap *= 2;
        char* nb = (char*)realloc(*buf, new_cap);
        if (!nb) return 0;
        *buf = nb;
        *cap = new_cap;
    }
    memcpy(*buf + *len, src, n);
    *len += n;
    return 1;
}

static int win_err_to_errno(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:     return ENOENT;
        case ERROR_ACCESS_DENIED:      return EACCES;
        case ERROR_BAD_EXE_FORMAT:     return ENOEXEC;
        case ERROR_NOT_ENOUGH_MEMORY:
        case ERROR_OUTOFMEMORY:        return ENOMEM;
        case ERROR_INVALID_PARAMETER:  return EINVAL;
        case ERROR_TOO_MANY_OPEN_FILES:return EMFILE;
        default:                       return EINVAL;
    }
}

// Append one argument to the command line with MSVCRT-compatible
// quoting (the algorithm documented in "Parsing C Command-Line
// Arguments"): quote when the arg contains whitespace/quotes/empty,
// double backslashes only when they precede a quote.
static int cmdline_append_arg(char** buf, size_t* len, size_t* cap,
                              const char* arg) {
    size_t alen = strlen(arg);
    int need_quotes = (alen == 0) || (strpbrk(arg, " \t\"") != NULL);
    if (!need_quotes) {
        return buf_append(buf, len, cap, arg, alen);
    }
    if (!buf_append(buf, len, cap, "\"", 1)) return 0;
    size_t bs = 0;
    for (size_t i = 0; i < alen; ++i) {
        char c = arg[i];
        if (c == '\\') {
            bs++;
            continue;
        }
        if (c == '"') {
            // Backslashes before a quote must be doubled, plus one to
            // escape the quote itself.
            for (size_t k = 0; k < bs * 2 + 1; ++k)
                if (!buf_append(buf, len, cap, "\\", 1)) return 0;
            bs = 0;
            if (!buf_append(buf, len, cap, "\"", 1)) return 0;
            continue;
        }
        for (size_t k = 0; k < bs; ++k)
            if (!buf_append(buf, len, cap, "\\", 1)) return 0;
        bs = 0;
        if (!buf_append(buf, len, cap, &c, 1)) return 0;
    }
    // Trailing backslashes precede the closing quote → double them.
    for (size_t k = 0; k < bs * 2; ++k)
        if (!buf_append(buf, len, cap, "\\", 1)) return 0;
    return buf_append(buf, len, cap, "\"", 1);
}

static char* build_cmdline(char* const* argv) {
    char* buf = NULL;
    size_t len = 0, cap = 0;
    for (size_t i = 0; argv[i] != NULL; ++i) {
        if (i > 0 && !buf_append(&buf, &len, &cap, " ", 1)) goto fail;
        if (!cmdline_append_arg(&buf, &len, &cap, argv[i])) goto fail;
    }
    if (!buf_append(&buf, &len, &cap, "\0", 1)) goto fail;
    return buf;
fail:
    free(buf);
    return NULL;
}

// Drain whatever is currently readable on `pipe` without blocking.
// Returns 1 while the pipe is alive, 0 once it reports broken/EOF.
static int drain_pipe(HANDLE pipe, char** buf, size_t* len, size_t* cap,
                      int* made_progress) {
    for (;;) {
        DWORD avail = 0;
        if (!PeekNamedPipe(pipe, NULL, 0, NULL, &avail, NULL)) {
            return 0; // ERROR_BROKEN_PIPE → child closed its end.
        }
        if (avail == 0) return 1;
        char scratch[4096];
        DWORD to_read = avail < sizeof(scratch) ? avail : (DWORD)sizeof(scratch);
        DWORD nread = 0;
        if (!ReadFile(pipe, scratch, to_read, &nread, NULL)) {
            return 0;
        }
        if (nread == 0) return 0;
        buf_append(buf, len, cap, scratch, (size_t)nread);
        *made_progress = 1;
    }
}

int zjs_process_spawn_capture(const char* file, char* const* argv,
                              const char* cwd,
                              const char* in_data, size_t in_len,
                              char** out_buf_p, size_t* out_len_p,
                              char** err_buf_p, size_t* err_len_p,
                              int* status_out, int* signal_out,
                              int* err_no_out) {
    *out_buf_p = NULL; *out_len_p = 0;
    *err_buf_p = NULL; *err_len_p = 0;
    *status_out = 0; *signal_out = 0;

    int want_stdin = (in_data != NULL && in_len > 0);

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    HANDLE in_r = NULL,  in_w = NULL;
    HANDLE out_r = NULL, out_w = NULL;
    HANDLE err_r = NULL, err_w = NULL;
    char* cmdline = NULL;
    int rc = -1;

    if (!CreatePipe(&out_r, &out_w, &sa, 0) ||
        !CreatePipe(&err_r, &err_w, &sa, 0) ||
        !CreatePipe(&in_r, &in_w, &sa, 0)) {
        *err_no_out = win_err_to_errno(GetLastError());
        goto cleanup;
    }
    // Parent-side ends must not leak into the child.
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(in_w,  HANDLE_FLAG_INHERIT, 0);

    cmdline = build_cmdline(argv);
    if (!cmdline) {
        *err_no_out = ENOMEM;
        goto cleanup;
    }

    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput  = in_r;
    si.hStdOutput = out_w;
    si.hStdError  = err_w;

    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));

    // lpApplicationName = NULL → the first cmdline token is resolved
    // against PATH with .exe appended, matching execvp's search.
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW, NULL,
                        (cwd && *cwd) ? cwd : NULL, &si, &pi)) {
        *err_no_out = win_err_to_errno(GetLastError());
        goto cleanup;
    }
    CloseHandle(pi.hThread);

    // Child owns its ends now; close ours so EOF propagates.
    CloseHandle(in_r);  in_r = NULL;
    CloseHandle(out_w); out_w = NULL;
    CloseHandle(err_w); err_w = NULL;

    // Feed stdin, then close to signal EOF. (Same ordering caveat as
    // the POSIX impl: all of stdin is written before output draining
    // starts — fine for the sync API's typical small inputs.)
    if (want_stdin) {
        size_t written = 0;
        while (written < in_len) {
            DWORD n = 0;
            DWORD chunk = (in_len - written) > 1u << 20 ? 1u << 20
                          : (DWORD)(in_len - written);
            if (!WriteFile(in_w, in_data + written, chunk, &n, NULL)) break;
            written += n;
        }
    }
    CloseHandle(in_w); in_w = NULL;

    // Drain both pipes until they break (child exited + buffers empty).
    size_t out_cap = 0, err_cap = 0;
    int out_alive = 1, err_alive = 1;
    while (out_alive || err_alive) {
        int progress = 0;
        if (out_alive)
            out_alive = drain_pipe(out_r, out_buf_p, out_len_p, &out_cap, &progress);
        if (err_alive)
            err_alive = drain_pipe(err_r, err_buf_p, err_len_p, &err_cap, &progress);
        if (!progress && (out_alive || err_alive)) {
            // Nothing readable right now — block briefly on the
            // process handle instead of spinning. The pipes still get
            // re-peeked after the wait regardless of why it returned.
            WaitForSingleObject(pi.hProcess, 10);
        }
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(pi.hProcess, &exit_code)) exit_code = 0;
    CloseHandle(pi.hProcess);
    *status_out = (int)exit_code;
    *signal_out = 0;
    rc = 0;

cleanup:
    if (in_r)  CloseHandle(in_r);
    if (in_w)  CloseHandle(in_w);
    if (out_r) CloseHandle(out_r);
    if (out_w) CloseHandle(out_w);
    if (err_r) CloseHandle(err_r);
    if (err_w) CloseHandle(err_w);
    free(cmdline);
    return rc;
}

#endif // _WIN32
