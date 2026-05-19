// Windows-native HTTP backend — WinHTTP (winhttp.dll).
//
// Mirrors src/platform/http_apple.m's contract on top of the WinHTTP
// session/connect/request handle hierarchy. WinHTTP gives us HTTPS,
// HTTP/2 (Win 10+), the system proxy (WPAD / netsh winhttp settings),
// IPv6, and the system trust store — same "platform-native gets us
// crypto and policy for free" trade-off the Apple backend makes via
// NSURLSession.
//
// All of WinHTTP's string surface is UTF-16, so we marshal in and out
// via MultiByteToWideChar / WideCharToMultiByte with CP_UTF8. Response
// body bytes pass through unchanged (binary-safe).
//
// Linked via `#pragma comment(lib, "winhttp.lib")` below so MSVC,
// clang-cl, and zig cc pick the import library up automatically. Pure
// gcc/mingw doesn't honor that pragma — those builds need `-lwinhttp`
// on the link line.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#include "http_native.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#if defined(__GNUC__) && !defined(__clang__)
// gcc ignores #pragma comment(lib, ...); link with -lwinhttp instead.
#else
#pragma comment(lib, "winhttp.lib")
#endif

// UTF-8 -> UTF-16. Returns a malloc'd, NUL-terminated wide string.
// `len` is the byte length of `utf8`; pass 0 for an empty string.
// NULL on allocation or conversion failure.
static wchar_t* utf8_to_wide(const char* utf8, size_t len) {
    if (utf8 == NULL) return NULL;
    if (len == 0) {
        wchar_t* empty = (wchar_t*)malloc(sizeof(wchar_t));
        if (empty != NULL) empty[0] = L'\0';
        return empty;
    }
    int in_len = (int)len;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8, in_len, NULL, 0);
    if (wlen <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
    if (w == NULL) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, utf8, in_len, w, wlen);
    w[wlen] = L'\0';
    return w;
}

// UTF-16 -> UTF-8. Returns a malloc'd, NUL-terminated cstring.
// `wlen` is the wchar count of `wide` (NOT bytes); pass -1 to let the
// API derive it from a NUL terminator.
static char* wide_to_utf8(const wchar_t* wide, int wlen) {
    if (wide == NULL) {
        char* empty = (char*)malloc(1);
        if (empty != NULL) empty[0] = '\0';
        return empty;
    }
    int blen = WideCharToMultiByte(CP_UTF8, 0, wide, wlen, NULL, 0, NULL, NULL);
    if (blen < 0) blen = 0;
    char* s = (char*)malloc((size_t)blen + 1);
    if (s == NULL) return NULL;
    if (blen > 0) {
        WideCharToMultiByte(CP_UTF8, 0, wide, wlen, s, blen, NULL, NULL);
    }
    s[blen] = '\0';
    return s;
}

// Build an error string for a Win32 error code, formatted to match
// the Apple backend's "fetch: <reason>" shape so the engine surfaces
// a consistent message regardless of platform.
static char* format_win32_error(const char* op, DWORD code) {
    LPWSTR sys_buf = NULL;
    // WinHTTP error codes live in winhttp.dll's message table, not
    // the system one — FormatMessage needs FROM_HMODULE for those.
    DWORD chars = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_FROM_HMODULE | FORMAT_MESSAGE_IGNORE_INSERTS,
        GetModuleHandleW(L"winhttp.dll"),
        code,
        0,
        (LPWSTR)&sys_buf,
        0,
        NULL);

    char header[160];
    if (op == NULL) op = "request";
    snprintf(header, sizeof header, "fetch: %s failed (WinHTTP error %lu)",
             op, (unsigned long)code);

    if (chars == 0 || sys_buf == NULL) {
        if (sys_buf) LocalFree(sys_buf);
        return _strdup(header);
    }

    // Trim trailing CR/LF/space the system tacks on.
    while (chars > 0 &&
           (sys_buf[chars - 1] == L'\r' ||
            sys_buf[chars - 1] == L'\n' ||
            sys_buf[chars - 1] == L' ')) {
        sys_buf[--chars] = L'\0';
    }

    char* tail = wide_to_utf8(sys_buf, (int)chars);
    LocalFree(sys_buf);
    if (tail == NULL) return _strdup(header);

    size_t hlen = strlen(header);
    size_t tlen = strlen(tail);
    char* full = (char*)malloc(hlen + 2 + tlen + 1);
    if (full == NULL) { free(tail); return _strdup(header); }
    memcpy(full, header, hlen);
    full[hlen] = ':';
    full[hlen + 1] = ' ';
    memcpy(full + hlen + 2, tail, tlen);
    full[hlen + 2 + tlen] = '\0';
    free(tail);
    return full;
}

void zjs_http_response_free(ZjsHttpResponse* resp) {
    if (resp == NULL) return;
    if (resp->body != NULL) {
        free(resp->body);
        resp->body = NULL;
    }
    resp->body_len = 0;
    if (resp->resp_headers != NULL) {
        size_t n = resp->resp_header_count * 2;
        for (size_t i = 0; i < n; i++) {
            if (resp->resp_headers[i] != NULL) free(resp->resp_headers[i]);
        }
        free(resp->resp_headers);
        resp->resp_headers = NULL;
    }
    resp->resp_header_count = 0;
    resp->status = 0;
}

// Parse the CRLF-separated raw header block returned by
// WinHttpQueryHeaders(WINHTTP_QUERY_RAW_HEADERS_CRLF) into the flat
// [name, value, ...] form the engine expects. The first line is the
// HTTP status line and is skipped — we already have the status code
// from a separate query. Two trailing CRLFs terminate the block.
static void parse_raw_headers_crlf(const wchar_t* raw,
                                   ZjsHttpResponse* resp) {
    if (raw == NULL) return;

    size_t total_lines = 0;
    for (const wchar_t* p = raw; *p != L'\0'; ) {
        const wchar_t* line_start = p;
        while (*p != L'\0' && *p != L'\r' && *p != L'\n') p++;
        if (p > line_start) total_lines++;
        while (*p == L'\r' || *p == L'\n') p++;
    }
    if (total_lines <= 1) return;
    size_t header_lines = total_lines - 1;

    char** flat = (char**)calloc(header_lines * 2, sizeof(char*));
    if (flat == NULL) return;

    size_t pair_idx = 0;
    int seen_status_line = 0;

    for (const wchar_t* p = raw; *p != L'\0' && pair_idx < header_lines; ) {
        const wchar_t* line_start = p;
        while (*p != L'\0' && *p != L'\r' && *p != L'\n') p++;
        size_t line_len = (size_t)(p - line_start);
        while (*p == L'\r' || *p == L'\n') p++;
        if (line_len == 0) continue;

        if (!seen_status_line) {
            // HTTP/1.1 200 OK — skip.
            seen_status_line = 1;
            continue;
        }

        size_t colon = 0;
        while (colon < line_len && line_start[colon] != L':') colon++;
        if (colon == line_len) continue; // malformed, skip

        size_t name_len = colon;
        size_t v_start = colon + 1;
        while (v_start < line_len &&
               (line_start[v_start] == L' ' || line_start[v_start] == L'\t')) {
            v_start++;
        }
        size_t val_len = line_len - v_start;

        char* name = wide_to_utf8(line_start, (int)name_len);
        char* value = val_len > 0
            ? wide_to_utf8(line_start + v_start, (int)val_len)
            : _strdup("");
        if (name == NULL || value == NULL) {
            free(name); free(value);
            continue;
        }
        flat[pair_idx * 2]     = name;
        flat[pair_idx * 2 + 1] = value;
        pair_idx++;
    }

    if (pair_idx == 0) {
        free(flat);
        return;
    }
    resp->resp_headers = flat;
    resp->resp_header_count = pair_idx;
}

int zjs_http_request_sync(const ZjsHttpRequest* req,
                          ZjsHttpResponse* resp,
                          char** err_out) {
    if (resp != NULL) {
        resp->status = 0;
        resp->body = NULL;
        resp->body_len = 0;
        resp->resp_headers = NULL;
        resp->resp_header_count = 0;
    }
    if (err_out) *err_out = NULL;

    if (req == NULL || req->url == NULL) {
        if (err_out) *err_out = _strdup("fetch: missing url");
        return -1;
    }

    int rc = -1;
    wchar_t* w_url     = NULL;
    wchar_t* w_method  = NULL;
    wchar_t* w_host    = NULL;
    wchar_t* w_path    = NULL;
    wchar_t* w_headers = NULL;
    HINTERNET h_session = NULL;
    HINTERNET h_conn    = NULL;
    HINTERNET h_req     = NULL;
    char* body_buf   = NULL;
    size_t body_len  = 0;
    size_t body_cap  = 0;

    w_url = utf8_to_wide(req->url, strlen(req->url));
    if (w_url == NULL) {
        if (err_out) *err_out = _strdup("fetch: invalid URL encoding");
        goto done;
    }

    URL_COMPONENTS uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize      = sizeof uc;
    uc.dwSchemeLength    = (DWORD)-1;
    uc.dwHostNameLength  = (DWORD)-1;
    uc.dwUrlPathLength   = (DWORD)-1;
    uc.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(w_url, 0, 0, &uc)) {
        if (err_out) *err_out = format_win32_error("URL parse", GetLastError());
        goto done;
    }

    int is_https =
        (uc.nScheme == INTERNET_SCHEME_HTTPS) ? 1 : 0;
    if (uc.nScheme != INTERNET_SCHEME_HTTP && !is_https) {
        if (err_out) *err_out =
            _strdup("fetch: only http and https URLs are supported");
        goto done;
    }

    w_host = (wchar_t*)malloc(((size_t)uc.dwHostNameLength + 1) * sizeof(wchar_t));
    if (w_host == NULL) {
        if (err_out) *err_out = _strdup("fetch: out of memory");
        goto done;
    }
    memcpy(w_host, uc.lpszHostName, uc.dwHostNameLength * sizeof(wchar_t));
    w_host[uc.dwHostNameLength] = L'\0';

    // Path + query — WinHttpOpenRequest's lpszObjectName is the path
    // including the query string. Concatenate uc.lpszUrlPath and
    // uc.lpszExtraInfo. Default to "/" if both empty.
    size_t path_chars = (size_t)uc.dwUrlPathLength + (size_t)uc.dwExtraInfoLength;
    if (path_chars == 0) path_chars = 1;
    w_path = (wchar_t*)malloc((path_chars + 1) * sizeof(wchar_t));
    if (w_path == NULL) {
        if (err_out) *err_out = _strdup("fetch: out of memory");
        goto done;
    }
    if (uc.dwUrlPathLength == 0 && uc.dwExtraInfoLength == 0) {
        w_path[0] = L'/';
        w_path[1] = L'\0';
    } else {
        size_t off = 0;
        if (uc.dwUrlPathLength > 0) {
            memcpy(w_path + off, uc.lpszUrlPath,
                   uc.dwUrlPathLength * sizeof(wchar_t));
            off += uc.dwUrlPathLength;
        }
        if (uc.dwExtraInfoLength > 0) {
            memcpy(w_path + off, uc.lpszExtraInfo,
                   uc.dwExtraInfoLength * sizeof(wchar_t));
            off += uc.dwExtraInfoLength;
        }
        w_path[off] = L'\0';
    }

    const char* method = (req->method && req->method[0]) ? req->method : "GET";
    w_method = utf8_to_wide(method, strlen(method));
    if (w_method == NULL) {
        if (err_out) *err_out = _strdup("fetch: invalid method encoding");
        goto done;
    }

    h_session = WinHttpOpen(L"zjs/0.0.1",
                            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                            WINHTTP_NO_PROXY_NAME,
                            WINHTTP_NO_PROXY_BYPASS,
                            0);
    if (h_session == NULL) {
        if (err_out) *err_out = format_win32_error("session open", GetLastError());
        goto done;
    }

    int timeout = (req->timeout_seconds > 0) ? req->timeout_seconds : 30;
    DWORD ms = (DWORD)timeout * 1000u;
    // (resolve, connect, send, receive) — keep them uniform; matches
    // the single timeoutInterval the Apple backend hands NSURLSession.
    WinHttpSetTimeouts(h_session, (int)ms, (int)ms, (int)ms, (int)ms);

    h_conn = WinHttpConnect(h_session, w_host, uc.nPort, 0);
    if (h_conn == NULL) {
        if (err_out) *err_out = format_win32_error("connect", GetLastError());
        goto done;
    }

    DWORD req_flags = is_https ? WINHTTP_FLAG_SECURE : 0;
    h_req = WinHttpOpenRequest(h_conn,
                               w_method,
                               w_path,
                               NULL,                    // HTTP/1.1
                               WINHTTP_NO_REFERER,
                               WINHTTP_DEFAULT_ACCEPT_TYPES,
                               req_flags);
    if (h_req == NULL) {
        if (err_out) *err_out = format_win32_error("open request", GetLastError());
        goto done;
    }

    // Build "Name: Value\r\n..." in one wide buffer and hand it to
    // WinHttpAddRequestHeaders in a single call. Cheaper than one
    // call per header and lets WinHTTP do its own validation pass.
    if (req->req_headers != NULL && req->req_header_count > 0) {
        size_t total = 0;
        for (size_t i = 0; i < req->req_header_count; i++) {
            const char* name  = req->req_headers[2*i];
            const char* value = req->req_headers[2*i + 1];
            if (name == NULL || value == NULL) continue;
            total += strlen(name) + 2 + strlen(value) + 2; // "N: V\r\n"
        }
        if (total > 0) {
            char* buf = (char*)malloc(total + 1);
            if (buf == NULL) {
                if (err_out) *err_out = _strdup("fetch: out of memory");
                goto done;
            }
            size_t off = 0;
            for (size_t i = 0; i < req->req_header_count; i++) {
                const char* name  = req->req_headers[2*i];
                const char* value = req->req_headers[2*i + 1];
                if (name == NULL || value == NULL) continue;
                size_t nl = strlen(name);
                size_t vl = strlen(value);
                memcpy(buf + off, name, nl); off += nl;
                buf[off++] = ':'; buf[off++] = ' ';
                memcpy(buf + off, value, vl); off += vl;
                buf[off++] = '\r'; buf[off++] = '\n';
            }
            buf[off] = '\0';
            w_headers = utf8_to_wide(buf, off);
            free(buf);
            if (w_headers == NULL) {
                if (err_out) *err_out = _strdup("fetch: header encoding failed");
                goto done;
            }
            if (!WinHttpAddRequestHeaders(h_req, w_headers,
                                          (DWORD)-1L,
                                          WINHTTP_ADDREQ_FLAG_ADD |
                                          WINHTTP_ADDREQ_FLAG_REPLACE)) {
                if (err_out) *err_out =
                    format_win32_error("add headers", GetLastError());
                goto done;
            }
        }
    }

    DWORD body_dw = (req->body != NULL) ? (DWORD)req->body_len : 0;
    LPVOID body_ptr = (req->body != NULL && req->body_len > 0)
                      ? (LPVOID)req->body
                      : WINHTTP_NO_REQUEST_DATA;
    if (!WinHttpSendRequest(h_req,
                            WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            body_ptr, body_dw,
                            body_dw,
                            0)) {
        if (err_out) *err_out = format_win32_error("send", GetLastError());
        goto done;
    }
    if (!WinHttpReceiveResponse(h_req, NULL)) {
        if (err_out) *err_out = format_win32_error("receive", GetLastError());
        goto done;
    }

    DWORD status_code = 0;
    DWORD status_size = sizeof status_code;
    if (!WinHttpQueryHeaders(h_req,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX,
                             &status_code,
                             &status_size,
                             WINHTTP_NO_HEADER_INDEX)) {
        if (err_out) *err_out = format_win32_error("query status", GetLastError());
        goto done;
    }
    resp->status = (int)status_code;

    // Raw headers (CRLF-separated). Two-call idiom: first call sizes
    // the buffer (returns FALSE + ERROR_INSUFFICIENT_BUFFER), then we
    // allocate and call again.
    DWORD raw_bytes = 0;
    WinHttpQueryHeaders(h_req,
                        WINHTTP_QUERY_RAW_HEADERS_CRLF,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        WINHTTP_NO_OUTPUT_BUFFER,
                        &raw_bytes,
                        WINHTTP_NO_HEADER_INDEX);
    if (raw_bytes > 0 && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        wchar_t* raw = (wchar_t*)malloc(raw_bytes);
        if (raw != NULL) {
            if (WinHttpQueryHeaders(h_req,
                                    WINHTTP_QUERY_RAW_HEADERS_CRLF,
                                    WINHTTP_HEADER_NAME_BY_INDEX,
                                    raw,
                                    &raw_bytes,
                                    WINHTTP_NO_HEADER_INDEX)) {
                parse_raw_headers_crlf(raw, resp);
            }
            free(raw);
        }
    }

    // Body — chunked drain via QueryDataAvailable + ReadData. We grow
    // body_buf with amortized doubling so a giant payload doesn't
    // realloc on every WinHTTP chunk.
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(h_req, &avail)) {
            if (err_out) *err_out =
                format_win32_error("read data available", GetLastError());
            free(body_buf); body_buf = NULL; body_len = 0;
            goto done;
        }
        if (avail == 0) break;

        if (body_len + avail + 1 > body_cap) {
            size_t new_cap = body_cap ? body_cap * 2 : 4096;
            while (new_cap < body_len + avail + 1) new_cap *= 2;
            char* grown = (char*)realloc(body_buf, new_cap);
            if (grown == NULL) {
                if (err_out) *err_out = _strdup("fetch: out of memory");
                free(body_buf); body_buf = NULL; body_len = 0;
                goto done;
            }
            body_buf = grown;
            body_cap = new_cap;
        }

        DWORD got = 0;
        if (!WinHttpReadData(h_req, body_buf + body_len, avail, &got)) {
            if (err_out) *err_out = format_win32_error("read data", GetLastError());
            free(body_buf); body_buf = NULL; body_len = 0;
            goto done;
        }
        if (got == 0) break;
        body_len += got;
    }
    if (body_len > 0) {
        resp->body = body_buf;
        resp->body_len = body_len;
        body_buf = NULL; // ownership transferred
    }

    rc = 0;

done:
    if (h_req)     WinHttpCloseHandle(h_req);
    if (h_conn)    WinHttpCloseHandle(h_conn);
    if (h_session) WinHttpCloseHandle(h_session);
    free(body_buf);
    free(w_headers);
    free(w_path);
    free(w_host);
    free(w_method);
    free(w_url);

    if (rc != 0) {
        zjs_http_response_free(resp);
        return -1;
    }
    return 0;
}
