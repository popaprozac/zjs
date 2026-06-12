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
#include <pthread.h>

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

// ---------------------------------------------------------------------
// data: URLs (RFC 2397). WinHTTP only speaks http/https; NSURLSession
// decodes data: natively on Apple, so parity demands we do it here.
//   data:[<mediatype>][;base64],<payload>
// ---------------------------------------------------------------------

static int data_url_b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;   // '=' padding and whitespace handled by the caller
}

// Decode `src` (b64, whitespace tolerated) into a malloc'd buffer.
// Returns 0 + *out/*out_len on success, -1 on malformed input.
static int data_url_b64_decode(const char* src, size_t n,
                               char** out, size_t* out_len) {
    char* buf = (char*)malloc(n ? (n / 4 + 1) * 3 : 1);
    if (!buf) return -1;
    size_t produced = 0;
    int acc = 0, bits = 0;
    for (size_t i = 0; i < n; i++) {
        char c = src[i];
        if (c == '=' || c == '\r' || c == '\n' || c == ' ' || c == '\t') continue;
        int v = data_url_b64_val(c);
        if (v < 0) { free(buf); return -1; }
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            buf[produced++] = (char)((acc >> bits) & 0xFF);
        }
    }
    *out = buf;
    *out_len = produced;
    return 0;
}

static int data_url_hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Percent-decode `src` into a malloc'd buffer (never fails on
// malformed escapes — they pass through literally, matching browsers).
static int data_url_pct_decode(const char* src, size_t n,
                               char** out, size_t* out_len) {
    char* buf = (char*)malloc(n + 1);
    if (!buf) return -1;
    size_t produced = 0;
    for (size_t i = 0; i < n; i++) {
        if (src[i] == '%' && i + 2 < n) {
            int hi = data_url_hex_val(src[i+1]);
            int lo = data_url_hex_val(src[i+2]);
            if (hi >= 0 && lo >= 0) {
                buf[produced++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        buf[produced++] = src[i];
    }
    *out = buf;
    *out_len = produced;
    return 0;
}

// If `url` is a data: URL, decode it into `resp` (status 200 +
// content-type header) and return 1. Returns 0 when it's not data:
// (caller proceeds with WinHTTP); -1 + err_out on a malformed one.
static int try_data_url(const char* url, ZjsHttpResponse* resp, char** err_out) {
    if (_strnicmp(url, "data:", 5) != 0) return 0;
    const char* meta = url + 5;
    const char* comma = strchr(meta, ',');
    if (comma == NULL) {
        if (err_out) *err_out = _strdup("fetch: malformed data: URL (no comma)");
        return -1;
    }
    size_t meta_len = (size_t)(comma - meta);
    int is_base64 = 0;
    if (meta_len >= 7 && _strnicmp(comma - 7, ";base64", 7) == 0) {
        is_base64 = 1;
        meta_len -= 7;
    }
    // RFC 2397 default media type.
    const char* default_type = "text/plain;charset=US-ASCII";
    char* ctype;
    if (meta_len == 0) {
        ctype = _strdup(default_type);
    } else if (meta[0] == ';') {
        // "data:;charset=...,": type omitted, params present →
        // text/plain + the given params.
        ctype = (char*)malloc(10 + meta_len + 1);
        if (ctype) {
            memcpy(ctype, "text/plain", 10);
            memcpy(ctype + 10, meta, meta_len);
            ctype[10 + meta_len] = '\0';
        }
    } else {
        ctype = (char*)malloc(meta_len + 1);
        if (ctype) { memcpy(ctype, meta, meta_len); ctype[meta_len] = '\0'; }
    }

    const char* payload = comma + 1;
    size_t payload_len = strlen(payload);
    char* body = NULL;
    size_t body_len = 0;
    int rc = is_base64
                 ? data_url_b64_decode(payload, payload_len, &body, &body_len)
                 : data_url_pct_decode(payload, payload_len, &body, &body_len);
    if (rc != 0) {
        free(ctype);
        if (err_out) *err_out = _strdup("fetch: malformed data: URL payload");
        return -1;
    }

    resp->status   = 200;
    resp->body     = body;
    resp->body_len = body_len;
    char** flat = (char**)calloc(2, sizeof(char*));
    if (flat != NULL && ctype != NULL) {
        flat[0] = _strdup("content-type");
        flat[1] = ctype;
        resp->resp_headers = flat;
        resp->resp_header_count = 1;
    } else {
        free(flat);
        free(ctype);
    }
    return 1;
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

    int data_rc = try_data_url(req->url, resp, err_out);
    if (data_rc != 0) return data_rc > 0 ? 0 : -1;

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

// =====================================================================
// Async ABI — WinHTTP native (WINHTTP_FLAG_ASYNC + status callback).
//
// Replaces src/platform/http_async.c on Windows. The pthread-per-
// request shape that http_async.c uses works but spawns a fresh
// thread for every in-flight fetch; here the WinHTTP runtime
// drives the state machine via callbacks on its own thread pool,
// so Promise.all([fetch, fetch, ...]) doesn't spawn N pthreads.
//
// State machine:
//   start()             — create handles, kick off WinHttpSendRequest
//   SENDREQUEST_COMPLETE → WinHttpReceiveResponse
//   HEADERS_AVAILABLE    → query status + raw headers, then
//                          WinHttpQueryDataAvailable
//   DATA_AVAILABLE       → grow body buffer, WinHttpReadData
//   READ_COMPLETE        → resp_body_len += bytes; loop to
//                          QueryDataAvailable. If bytes==0 → done.
//   REQUEST_ERROR        → set err_msg, transition to ERROR.
//   HANDLE_CLOSING       — final callback after CloseHandle; the
//                          only point at which it's safe to free
//                          the handle struct.
//
// Lifecycle: destroy() sets `teardown=1` and calls
// WinHttpCloseHandle on the request handle (which cancels any
// in-flight op). The HANDLE_CLOSING callback that follows sees
// `teardown=1` and frees the handle struct. Poll() returns 0 in
// the meantime; the engine moves on.

typedef enum {
    HTTP_ASYNC_PENDING = 0,
    HTTP_ASYNC_DONE    = 1,
    HTTP_ASYNC_ERROR   = -1,
} HttpAsyncState;

struct ZjsHttpHandle {
    pthread_mutex_t lock;
    HttpAsyncState state;
    int teardown;
    int handle_closed; // HANDLE_CLOSING fired? — guards double-free

    // Caller inputs — owned copies so they outlive start().
    char* method;
    char* url;
    char** req_headers;
    size_t req_header_count;
    char* body;
    size_t body_len;
    int timeout_seconds;

    // Parsed URL pieces (UTF-16) — must outlive the request because
    // WinHTTP reads from them during the async chain.
    wchar_t* w_host;
    wchar_t* w_path;
    wchar_t* w_method;
    wchar_t* w_url;
    wchar_t* w_headers;       // combined "N: V\r\n..." block
    INTERNET_PORT port;
    int is_secure;

    // WinHTTP handles.
    HINTERNET h_session;
    HINTERNET h_conn;
    HINTERNET h_req;

    // Accumulated response.
    int      status;
    char*    resp_body;
    size_t   resp_body_len;
    size_t   resp_body_cap;
    char**   resp_headers;
    size_t   resp_header_count;
    char*    err_msg;
};

static void http_async_free(ZjsHttpHandle* h);

static char* xstrdup_or_null(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// Build the parsed URL and combined header block on the handle.
// Returns 0 on success, -1 + err_msg on failure.
static int http_async_prepare(ZjsHttpHandle* h) {
    h->w_url = utf8_to_wide(h->url, strlen(h->url));
    if (h->w_url == NULL) {
        h->err_msg = _strdup("fetch: invalid URL encoding");
        return -1;
    }
    URL_COMPONENTS uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize      = sizeof uc;
    uc.dwSchemeLength    = (DWORD)-1;
    uc.dwHostNameLength  = (DWORD)-1;
    uc.dwUrlPathLength   = (DWORD)-1;
    uc.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(h->w_url, 0, 0, &uc)) {
        h->err_msg = format_win32_error("URL parse", GetLastError());
        return -1;
    }
    h->is_secure = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? 1 : 0;
    if (uc.nScheme != INTERNET_SCHEME_HTTP && !h->is_secure) {
        h->err_msg = _strdup("fetch: only http and https URLs are supported");
        return -1;
    }
    h->port = uc.nPort;

    h->w_host = (wchar_t*)malloc(((size_t)uc.dwHostNameLength + 1) * sizeof(wchar_t));
    if (h->w_host == NULL) { h->err_msg = _strdup("fetch: out of memory"); return -1; }
    memcpy(h->w_host, uc.lpszHostName, uc.dwHostNameLength * sizeof(wchar_t));
    h->w_host[uc.dwHostNameLength] = L'\0';

    size_t path_chars = (size_t)uc.dwUrlPathLength + (size_t)uc.dwExtraInfoLength;
    if (path_chars == 0) path_chars = 1;
    h->w_path = (wchar_t*)malloc((path_chars + 1) * sizeof(wchar_t));
    if (h->w_path == NULL) { h->err_msg = _strdup("fetch: out of memory"); return -1; }
    if (uc.dwUrlPathLength == 0 && uc.dwExtraInfoLength == 0) {
        h->w_path[0] = L'/'; h->w_path[1] = L'\0';
    } else {
        size_t off = 0;
        if (uc.dwUrlPathLength > 0) {
            memcpy(h->w_path + off, uc.lpszUrlPath,
                   uc.dwUrlPathLength * sizeof(wchar_t));
            off += uc.dwUrlPathLength;
        }
        if (uc.dwExtraInfoLength > 0) {
            memcpy(h->w_path + off, uc.lpszExtraInfo,
                   uc.dwExtraInfoLength * sizeof(wchar_t));
            off += uc.dwExtraInfoLength;
        }
        h->w_path[off] = L'\0';
    }

    const char* method = (h->method && h->method[0]) ? h->method : "GET";
    h->w_method = utf8_to_wide(method, strlen(method));
    if (h->w_method == NULL) {
        h->err_msg = _strdup("fetch: invalid method encoding");
        return -1;
    }

    // Build a single Name:Value\r\n... block for WinHttpAddRequestHeaders.
    if (h->req_headers != NULL && h->req_header_count > 0) {
        size_t total = 0;
        for (size_t i = 0; i < h->req_header_count; i++) {
            const char* name  = h->req_headers[2*i];
            const char* value = h->req_headers[2*i + 1];
            if (name == NULL || value == NULL) continue;
            total += strlen(name) + 2 + strlen(value) + 2;
        }
        if (total > 0) {
            char* buf = (char*)malloc(total + 1);
            if (buf != NULL) {
                size_t off = 0;
                for (size_t i = 0; i < h->req_header_count; i++) {
                    const char* name  = h->req_headers[2*i];
                    const char* value = h->req_headers[2*i + 1];
                    if (name == NULL || value == NULL) continue;
                    size_t nl = strlen(name), vl = strlen(value);
                    memcpy(buf + off, name, nl); off += nl;
                    buf[off++] = ':'; buf[off++] = ' ';
                    memcpy(buf + off, value, vl); off += vl;
                    buf[off++] = '\r'; buf[off++] = '\n';
                }
                buf[off] = '\0';
                h->w_headers = utf8_to_wide(buf, off);
                free(buf);
            }
        }
    }
    return 0;
}

// Caller holds h->lock.
static void http_async_set_error_locked(ZjsHttpHandle* h, const char* op, DWORD code) {
    if (h->err_msg != NULL) free(h->err_msg);
    h->err_msg = format_win32_error(op, code);
    h->state = HTTP_ASYNC_ERROR;
}

// HEADERS_AVAILABLE callback: query status + the raw header block
// and stash them on the handle. Caller holds h->lock.
static void http_async_capture_headers_locked(ZjsHttpHandle* h) {
    DWORD status_code = 0;
    DWORD status_size = sizeof status_code;
    if (!WinHttpQueryHeaders(h->h_req,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX,
                             &status_code,
                             &status_size,
                             WINHTTP_NO_HEADER_INDEX)) {
        http_async_set_error_locked(h, "query status", GetLastError());
        return;
    }
    h->status = (int)status_code;

    DWORD raw_bytes = 0;
    WinHttpQueryHeaders(h->h_req,
                        WINHTTP_QUERY_RAW_HEADERS_CRLF,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        WINHTTP_NO_OUTPUT_BUFFER,
                        &raw_bytes,
                        WINHTTP_NO_HEADER_INDEX);
    if (raw_bytes > 0 && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        wchar_t* raw = (wchar_t*)malloc(raw_bytes);
        if (raw != NULL) {
            if (WinHttpQueryHeaders(h->h_req,
                                    WINHTTP_QUERY_RAW_HEADERS_CRLF,
                                    WINHTTP_HEADER_NAME_BY_INDEX,
                                    raw,
                                    &raw_bytes,
                                    WINHTTP_NO_HEADER_INDEX)) {
                // Reuse the sync impl's parser; it writes resp_headers
                // + resp_header_count on a transient ZjsHttpResponse,
                // and we transfer those onto the handle.
                ZjsHttpResponse tmp;
                memset(&tmp, 0, sizeof tmp);
                parse_raw_headers_crlf(raw, &tmp);
                h->resp_headers      = tmp.resp_headers;
                h->resp_header_count = tmp.resp_header_count;
            }
            free(raw);
        }
    }
}

// Grow resp_body to fit at least `want` more bytes; returns 0 on
// success, -1 on OOM (caller sets error). Holds h->lock.
static int http_async_reserve_body_locked(ZjsHttpHandle* h, size_t want) {
    size_t need = h->resp_body_len + want + 1;
    if (need <= h->resp_body_cap) return 0;
    size_t new_cap = h->resp_body_cap ? h->resp_body_cap * 2 : 4096;
    while (new_cap < need) new_cap *= 2;
    char* g = (char*)realloc(h->resp_body, new_cap);
    if (g == NULL) return -1;
    h->resp_body = g;
    h->resp_body_cap = new_cap;
    return 0;
}

// WinHTTP status callback. Fires from worker threads in WinHTTP's
// internal pool. Critical: WinHTTP can invoke the *next* callback
// synchronously from within its own async call (e.g., when a small
// response completes mid-call) — so we must NEVER hold h->lock
// across a WinHttp* call, or we deadlock the same thread against a
// non-recursive mutex. The pattern: lock, mutate state / read
// state, decide what's next, unlock, issue the next async op
// outside the lock.
static void CALLBACK http_async_cb(HINTERNET hInternet, DWORD_PTR ctx,
                                   DWORD status, LPVOID info, DWORD infoLen) {
    (void)hInternet;
    ZjsHttpHandle* h = (ZjsHttpHandle*)ctx;
    if (h == NULL) return;

    if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        // Last callback for h_req — safe to free now. Mark handle
        // already closed so destroy doesn't double-CloseHandle.
        pthread_mutex_lock(&h->lock);
        h->h_req = NULL;
        int teardown = h->teardown;
        h->handle_closed = 1;
        pthread_mutex_unlock(&h->lock);
        if (teardown) {
            http_async_free(h);
        }
        return;
    }

    // Skip the bulk of the callback once we're done / errored — only
    // the *_COMPLETE / DATA_AVAILABLE / READ_COMPLETE statuses drive
    // the state machine, and they all assume PENDING.
    pthread_mutex_lock(&h->lock);
    if (h->teardown || h->state != HTTP_ASYNC_PENDING) {
        pthread_mutex_unlock(&h->lock);
        return;
    }

    // Decide what to do next; mutate state under the lock; capture
    // whatever the next WinHttp call needs into locals; release;
    // then call. `next` says which (if any) async op to fire.
    enum {
        NEXT_NONE = 0,
        NEXT_RECV,           // WinHttpReceiveResponse
        NEXT_QUERY_AVAIL,    // WinHttpQueryDataAvailable
        NEXT_READ,           // WinHttpReadData(buf, want)
    } next = NEXT_NONE;
    DWORD want = 0;
    char* read_into = NULL;
    const char* err_op = NULL;
    DWORD       err_code = 0;

    switch (status) {
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
        next = NEXT_RECV;
        break;

    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        // Header queries are sync — safe to call under the lock.
        http_async_capture_headers_locked(h);
        if (h->state == HTTP_ASYNC_PENDING) next = NEXT_QUERY_AVAIL;
        break;

    case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE: {
        DWORD avail = (info != NULL) ? *(DWORD*)info : 0;
        if (avail == 0) {
            h->state = HTTP_ASYNC_DONE;
            break;
        }
        if (http_async_reserve_body_locked(h, avail) != 0) {
            http_async_set_error_locked(h, "out of memory", 0);
            break;
        }
        want      = avail;
        read_into = h->resp_body + h->resp_body_len;
        next      = NEXT_READ;
        break;
    }

    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE: {
        DWORD got = infoLen;
        if (got == 0) {
            h->state = HTTP_ASYNC_DONE;
            break;
        }
        h->resp_body_len += got;
        next = NEXT_QUERY_AVAIL;
        break;
    }

    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR: {
        WINHTTP_ASYNC_RESULT* ar = (WINHTTP_ASYNC_RESULT*)info;
        http_async_set_error_locked(h, "async error",
                                    ar ? ar->dwError : 0);
        break;
    }

    default:
        break;
    }

    HINTERNET h_req = h->h_req;
    pthread_mutex_unlock(&h->lock);

    if (next != NEXT_NONE && h_req != NULL) {
        BOOL rc = TRUE;
        switch (next) {
        case NEXT_RECV:
            rc = WinHttpReceiveResponse(h_req, NULL);
            if (!rc) { err_op = "receive response"; err_code = GetLastError(); }
            break;
        case NEXT_QUERY_AVAIL:
            rc = WinHttpQueryDataAvailable(h_req, NULL);
            if (!rc) { err_op = "query data available"; err_code = GetLastError(); }
            break;
        case NEXT_READ:
            rc = WinHttpReadData(h_req, read_into, want, NULL);
            if (!rc) { err_op = "read data"; err_code = GetLastError(); }
            break;
        default:
            break;
        }
        if (err_op != NULL) {
            pthread_mutex_lock(&h->lock);
            if (h->state == HTTP_ASYNC_PENDING) {
                http_async_set_error_locked(h, err_op, err_code);
            }
            pthread_mutex_unlock(&h->lock);
        }
    }
}

// Build the WinHTTP handle chain in async mode and kick off the
// initial WinHttpSendRequest. Returns 0 on success, -1 on failure
// (h->err_msg is set; caller's free path runs).
static int http_async_kick_off(ZjsHttpHandle* h) {
    h->h_session = WinHttpOpen(L"zjs/0.0.1",
                               WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME,
                               WINHTTP_NO_PROXY_BYPASS,
                               WINHTTP_FLAG_ASYNC);
    if (h->h_session == NULL) {
        h->err_msg = format_win32_error("session open", GetLastError());
        return -1;
    }

    // Install the callback on the session — it propagates to every
    // child handle (connection, request) automatically. Doing it
    // here, before WinHttpConnect, ensures the callback is in place
    // by the time any async op kicks off.
    DWORD cb_flags = WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS |
                     WINHTTP_CALLBACK_FLAG_REQUEST_ERROR   |
                     WINHTTP_CALLBACK_FLAG_HANDLES         |
                     WINHTTP_CALLBACK_FLAG_SECURE_FAILURE;
    if (WinHttpSetStatusCallback(h->h_session, http_async_cb,
                                 cb_flags,
                                 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
        h->err_msg = format_win32_error("set callback", GetLastError());
        return -1;
    }

    int timeout = (h->timeout_seconds > 0) ? h->timeout_seconds : 30;
    DWORD ms = (DWORD)timeout * 1000u;
    WinHttpSetTimeouts(h->h_session, (int)ms, (int)ms, (int)ms, (int)ms);

    h->h_conn = WinHttpConnect(h->h_session, h->w_host, h->port, 0);
    if (h->h_conn == NULL) {
        h->err_msg = format_win32_error("connect", GetLastError());
        return -1;
    }

    DWORD req_flags = h->is_secure ? WINHTTP_FLAG_SECURE : 0;
    h->h_req = WinHttpOpenRequest(h->h_conn,
                                  h->w_method,
                                  h->w_path,
                                  NULL,
                                  WINHTTP_NO_REFERER,
                                  WINHTTP_DEFAULT_ACCEPT_TYPES,
                                  req_flags);
    if (h->h_req == NULL) {
        h->err_msg = format_win32_error("open request", GetLastError());
        return -1;
    }

    DWORD_PTR ctx_val = (DWORD_PTR)h;
    if (!WinHttpSetOption(h->h_req, WINHTTP_OPTION_CONTEXT_VALUE,
                          &ctx_val, sizeof ctx_val)) {
        h->err_msg = format_win32_error("set context", GetLastError());
        return -1;
    }

    if (h->w_headers != NULL) {
        if (!WinHttpAddRequestHeaders(h->h_req, h->w_headers,
                                      (DWORD)-1L,
                                      WINHTTP_ADDREQ_FLAG_ADD |
                                      WINHTTP_ADDREQ_FLAG_REPLACE)) {
            h->err_msg = format_win32_error("add headers", GetLastError());
            return -1;
        }
    }

    DWORD body_dw = (h->body != NULL) ? (DWORD)h->body_len : 0;
    LPVOID body_ptr = (h->body != NULL && h->body_len > 0)
                      ? (LPVOID)h->body
                      : WINHTTP_NO_REQUEST_DATA;

    if (!WinHttpSendRequest(h->h_req,
                            WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            body_ptr, body_dw,
                            body_dw,
                            (DWORD_PTR)h)) {
        h->err_msg = format_win32_error("send request", GetLastError());
        return -1;
    }
    // Now we're driven entirely by callbacks until DONE / ERROR.
    return 0;
}

// Final free — only called when WinHTTP is done with the handles
// (HANDLE_CLOSING fired) or when start() failed before any async
// op kicked off. Closes session + conn (no callbacks fire for
// those) and frees everything.
static void http_async_free(ZjsHttpHandle* h) {
    if (h == NULL) return;
    if (h->h_req     != NULL) { WinHttpCloseHandle(h->h_req);     h->h_req = NULL; }
    if (h->h_conn    != NULL) { WinHttpCloseHandle(h->h_conn);    h->h_conn = NULL; }
    if (h->h_session != NULL) { WinHttpCloseHandle(h->h_session); h->h_session = NULL; }

    if (h->resp_body) free(h->resp_body);
    if (h->resp_headers) {
        size_t n = h->resp_header_count * 2;
        for (size_t i = 0; i < n; i++) {
            if (h->resp_headers[i]) free(h->resp_headers[i]);
        }
        free(h->resp_headers);
    }
    if (h->err_msg) free(h->err_msg);

    if (h->method) free(h->method);
    if (h->url)    free(h->url);
    if (h->body)   free(h->body);
    if (h->req_headers) {
        size_t n = h->req_header_count * 2;
        for (size_t i = 0; i < n; i++) {
            if (h->req_headers[i]) free(h->req_headers[i]);
        }
        free(h->req_headers);
    }
    if (h->w_host)    free(h->w_host);
    if (h->w_path)    free(h->w_path);
    if (h->w_method)  free(h->w_method);
    if (h->w_url)     free(h->w_url);
    if (h->w_headers) free(h->w_headers);

    pthread_mutex_destroy(&h->lock);
    free(h);
}

ZjsHttpHandle* zjs_http_request_start(const ZjsHttpRequest* req) {
    if (req == NULL || req->url == NULL) return NULL;
    ZjsHttpHandle* h = (ZjsHttpHandle*)calloc(1, sizeof(ZjsHttpHandle));
    if (h == NULL) return NULL;
    pthread_mutex_init(&h->lock, NULL);
    h->method = xstrdup_or_null(req->method ? req->method : "GET");
    h->url    = xstrdup_or_null(req->url);
    h->timeout_seconds = req->timeout_seconds;
    if (req->req_header_count > 0 && req->req_headers != NULL) {
        size_t n = req->req_header_count * 2;
        h->req_headers = (char**)calloc(n, sizeof(char*));
        if (h->req_headers != NULL) {
            for (size_t i = 0; i < n; i++) {
                h->req_headers[i] = xstrdup_or_null(req->req_headers[i]);
            }
            h->req_header_count = req->req_header_count;
        }
    }
    if (req->body_len > 0 && req->body != NULL) {
        h->body = (char*)malloc(req->body_len);
        if (h->body != NULL) {
            memcpy(h->body, req->body, req->body_len);
            h->body_len = req->body_len;
        }
    }

    // data: URLs complete inline — stash the decoded response on the
    // handle as already-DONE; poll() hands it over, destroy() frees
    // synchronously (no WinHTTP handles were ever opened).
    {
        ZjsHttpResponse dresp = {0};
        char* derr = NULL;
        int data_rc = try_data_url(h->url, &dresp, &derr);
        if (data_rc > 0) {
            h->status            = dresp.status;
            h->resp_body         = dresp.body;
            h->resp_body_len     = dresp.body_len;
            h->resp_headers      = dresp.resp_headers;
            h->resp_header_count = dresp.resp_header_count;
            h->state = HTTP_ASYNC_DONE;
            return h;
        }
        if (data_rc < 0) {
            h->err_msg = derr;
            h->state = HTTP_ASYNC_ERROR;
            return h;
        }
    }

    if (http_async_prepare(h) != 0) {
        h->state = HTTP_ASYNC_ERROR;
        // No callbacks have been installed yet; safe to return the
        // pre-failed handle and let the caller poll → destroy.
        return h;
    }
    if (http_async_kick_off(h) != 0) {
        h->state = HTTP_ASYNC_ERROR;
        // The callback may or may not have been installed at the
        // point of failure. If h_req exists, close it so HANDLE_CLOSING
        // fires + frees; otherwise the next destroy will free
        // synchronously. To keep destroy() the only owner of the
        // free path, just return — destroy is what the engine calls.
        return h;
    }
    return h;
}

int zjs_http_request_poll(ZjsHttpHandle* h, ZjsHttpResponse* out_resp, char** err_out) {
    if (h == NULL || out_resp == NULL) return -1;
    pthread_mutex_lock(&h->lock);
    HttpAsyncState s = h->state;
    if (s == HTTP_ASYNC_PENDING) {
        pthread_mutex_unlock(&h->lock);
        return 0;
    }
    if (s == HTTP_ASYNC_DONE) {
        out_resp->status            = h->status;
        out_resp->body              = h->resp_body;
        out_resp->body_len          = h->resp_body_len;
        out_resp->resp_headers      = h->resp_headers;
        out_resp->resp_header_count = h->resp_header_count;
        // Ownership transfers to caller; null out so destroy doesn't
        // double-free.
        h->resp_body         = NULL;
        h->resp_body_len     = 0;
        h->resp_body_cap     = 0;
        h->resp_headers      = NULL;
        h->resp_header_count = 0;
        pthread_mutex_unlock(&h->lock);
        return 1;
    }
    // ERROR
    if (err_out != NULL) {
        *err_out = h->err_msg;
        h->err_msg = NULL;
    }
    pthread_mutex_unlock(&h->lock);
    return -1;
}

void zjs_http_request_destroy(ZjsHttpHandle* h) {
    if (h == NULL) return;
    pthread_mutex_lock(&h->lock);
    h->teardown = 1;
    HINTERNET h_req = h->h_req;
    int already_closed = h->handle_closed;
    pthread_mutex_unlock(&h->lock);

    if (h_req != NULL && !already_closed) {
        // Triggers HANDLE_CLOSING; that callback frees the handle.
        // Don't touch h after this point — the callback owns it.
        WinHttpCloseHandle(h_req);
        return;
    }
    // No outstanding async op (either we never kicked off, or the
    // request finished and we already saw HANDLE_CLOSING). Free
    // synchronously.
    http_async_free(h);
}
