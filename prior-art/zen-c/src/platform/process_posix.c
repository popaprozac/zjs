// POSIX implementation of process_native.h — fork/execvp/poll/waitpid.
//
// Moved verbatim (modulo C-ification) from the original zc-level
// cp_spawn_capture in node_child_process.zc when the Windows port
// split the platform layer out (see process_windows.c).

#include "process_native.h"

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

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

int zjs_process_spawn_capture(const char* file, char* const* argv,
                              const char* cwd,
                              const char* in_data, size_t in_len,
                              char** out_buf_p, size_t* out_len_p,
                              char** err_buf_p, size_t* err_len_p,
                              int* status_out, int* signal_out,
                              int* err_no_out) {
    int stdin_p[2]  = {-1, -1};
    int stdout_p[2] = {-1, -1};
    int stderr_p[2] = {-1, -1};
    int want_stdin = (in_data != NULL && in_len > 0);

    if (want_stdin && pipe(stdin_p) < 0) { *err_no_out = errno; return -1; }
    if (pipe(stdout_p) < 0)              { *err_no_out = errno; return -1; }
    if (pipe(stderr_p) < 0)              { *err_no_out = errno; return -1; }

    pid_t pid = fork();
    if (pid < 0) {
        *err_no_out = errno;
        return -1;
    }
    if (pid == 0) {
        // === child ===
        if (want_stdin) {
            dup2(stdin_p[0], STDIN_FILENO);
            close(stdin_p[0]); close(stdin_p[1]);
        }
        dup2(stdout_p[1], STDOUT_FILENO);
        dup2(stderr_p[1], STDERR_FILENO);
        close(stdout_p[0]); close(stdout_p[1]);
        close(stderr_p[0]); close(stderr_p[1]);
        if (cwd && *cwd) {
            if (chdir(cwd) < 0) _exit(127);
        }
        execvp(file, argv);
        // Distinguish "not found" (ENOENT) from "no permission"
        // (EACCES) the way the shell does.
        _exit(errno == ENOENT ? 127 : 126);
    }

    // === parent ===
    close(stdout_p[1]);
    close(stderr_p[1]);
    if (want_stdin) close(stdin_p[0]);

    // Write stdin if any, then close.
    if (want_stdin) {
        size_t written = 0;
        while (written < in_len) {
            ssize_t n = write(stdin_p[1], in_data + written, in_len - written);
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            written += (size_t)n;
        }
        close(stdin_p[1]);
    }

    // Drain stdout + stderr via poll until both close.
    size_t out_cap = 0, err_cap = 0;
    *out_buf_p = NULL; *out_len_p = 0;
    *err_buf_p = NULL; *err_len_p = 0;
    char scratch[4096];
    int fds_open = 2;
    while (fds_open > 0) {
        struct pollfd pfds[2];
        pfds[0].fd = stdout_p[0]; pfds[0].events = POLLIN; pfds[0].revents = 0;
        pfds[1].fd = stderr_p[0]; pfds[1].events = POLLIN; pfds[1].revents = 0;
        int pr = poll(pfds, 2, -1);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < 2; ++i) {
            if (pfds[i].fd < 0) continue;
            if (pfds[i].revents == 0) continue;
            ssize_t nread = read(pfds[i].fd, scratch, sizeof(scratch));
            if (nread > 0) {
                if (i == 0) buf_append(out_buf_p, out_len_p, &out_cap, scratch, (size_t)nread);
                else        buf_append(err_buf_p, err_len_p, &err_cap, scratch, (size_t)nread);
            } else {
                // EOF or error → close this fd.
                close(pfds[i].fd);
                if (i == 0) stdout_p[0] = -1;
                else        stderr_p[0] = -1;
                fds_open--;
            }
        }
    }

    // Reap child.
    int wstatus = 0;
    for (;;) {
        pid_t wpid = waitpid(pid, &wstatus, 0);
        if (wpid >= 0) break;
        if (errno == EINTR) continue;
        *err_no_out = errno;
        return -1;
    }
    if (WIFEXITED(wstatus))        { *status_out = WEXITSTATUS(wstatus); *signal_out = 0; }
    else if (WIFSIGNALED(wstatus)) { *status_out = -1; *signal_out = WTERMSIG(wstatus); }
    else                           { *status_out = 0;  *signal_out = 0; }
    return 0;
}
