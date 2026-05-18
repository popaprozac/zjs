# Zen-c stdlib audit (2026-05-18)

Cross-walk between what zjs has built and what zen-c's stdlib already
provides. Per item:

- **Verdict — keep**: our implementation is required by JS spec quirks
  that the general-purpose stdlib doesn't model, OR is simpler than
  swapping. Status quo wins.
- **Verdict — switch**: stdlib is a clean replacement. Worth the
  refactor.
- **Verdict — adopt**: zjs doesn't have this yet; stdlib gives us the
  capability for free.

Canonical doc source: <https://github.com/zenc-lang/docs/tree/main/std>.
Module surface verified against `.md` docs (not the locally-installed
`.zc` files — upstream is ahead of `zc v0.4.4-217`).

---

## A. We built it; could stdlib do it?

### A1 — base64 (`atob` / `btoa`)

- **zjs:** `host_atob` / `host_btoa` in `context.zc` (~150 lines each).
  WHATWG semantics: Latin-1 binary strings (throws
  `InvalidCharacterError` on code points > 0xFF), whitespace stripping
  in `atob`, padding handling per RFC 4648.
- **std/encoding/base64:** `Base64::encode(u8*, len) -> char*`,
  `Base64::decode(char*) -> Vec<u8>`. RFC 4648.
- **Verdict — keep.** Our 30-line inline implementation is tighter
  than the impedance match: we'd still need the validation pass
  (`InvalidCharacterError` on > 0xFF for btoa, non-base64 chars for
  atob), and the byte buffer would need to be copied back into a
  ZjsString anyway. Net: zero lines saved, lose the spec-quirk
  guarantees.

### A2 — `URL` / `URLSearchParams`

- **zjs:** Full WHATWG-style parser in `context.zc`. Components:
  protocol, username, password, hostname, port, pathname, search,
  hash. Relative-against-base resolution with `./` / `../`
  normalization. `host` getter that elides default ports.
- **std/net/url:** `Url::parse(s: String) -> Option<Url>`. Component
  surface not documented in detail; from the source: scheme / host /
  port / path / query.
- **Verdict — keep.** WHATWG behavior (origin = `"null"` for
  non-special schemes, per-component percent-encoding sets,
  `searchParams` accessor) is JS-API-shaped and would require
  wrapper translation either way. Even if `Url::parse` is correct, we
  don't escape the constructor work.

### A3 — `JSON.stringify`

- **zjs:** Hand-rolled `json_buf_*` writer over a growable char
  buffer; walks ZjsValue directly. Handles `toJSON` short-circuit,
  cycle detection (via depth limit), `undefined` → omit, function →
  omit, NaN/Infinity → null.
- **std/json:** Full DOM. `JsonValue::object/array/string/number/bool/
  null` constructors + `set`/`push`/`get` mutation + `to_string()`
  serializer.
- **Verdict — keep, but verify replace cost.** Std/json is a tree
  IR — we'd have to walk ZjsValue, build a JsonValue tree, then
  serialize. Adds an O(n) intermediate allocation we don't need. Our
  direct-walk writer is the right architecture for stringify. **But**
  stdlib unlocks **JSON.parse** essentially free (we don't have it
  yet — see B1).

### A4 — `crypto.randomUUID` / `crypto.getRandomValues`

- **zjs:** `arc4random_buf` direct call inside host fn. CSPRNG.
- **std/random:** Wraps `rand()` / `srand()`. Non-CSPRNG.
- **Verdict — keep.** Web `crypto.*` requires cryptographic randomness;
  std/random is fine for `Math.random()` (see B5) but wrong for crypto.

### A5 — `Date.now` / `performance.now`

- **zjs:** Direct `clock_gettime(CLOCK_REALTIME, …)` for Date,
  `CLOCK_MONOTONIC` for performance.now.
- **std/time:** `Time::now() -> U64` milliseconds. `Duration::from_ms`
  for sleep. No sub-ms variant.
- **Verdict — switch Date.now, keep performance.now.** `Date.now()`
  spec is integer ms — `Time::now()` matches exactly. `performance.now`
  needs sub-ms precision; std/time can't deliver that. Small win, but
  removes one direct syscall call site.

### A6 — Module-loader path resolution

- **zjs:** `module_resolve_specifier` in `context.zc` — joins base
  dirname with spec then normalizes `./` / `../` in a single pass.
- **std/path:** `Path::join(self, other) -> Path` + `parent` +
  `extension` + `file_name`. No documented `./` / `../` normalization.
- **Verdict — keep, but note std covers helper bits.** Our work is
  the canonicalization pass; std covers the trivial join. Not worth
  swapping the canonicalization out. If we add a `path.join` JS API
  later (Node compat), std is the right backing.

### A7 — Module-loader file reading

- **zjs:** `read_file_to_string(path)` in `context.zc` — manual
  `fopen` + `fseek` + `fread`. Plus inline file slurp in `tools/zjs.zc`.
- **std/fs:** `File::read_all(path: char*) -> Result<String>`. Also
  `read_lines`, `exists`, `metadata`, `current_dir`, `create_dir`,
  `read_dir`. RAII via `Drop`.
- **Verdict — DEFER, not "cheap switch".** Looks like a drop-in but
  isn't: `String` is RAII-managed (`impl Drop for String` frees on
  scope-exit), and our module loader intentionally leaks the source
  buffer because the compiled `Function*` holds offsets into it. No
  `leak()` / `into_raw()` / `detach()` on `String` to transfer
  ownership out cleanly. A real switch needs a module-loader
  ownership refactor (have Function take ownership of the source
  buffer); that's a separate task. Keep our `fopen` for now.
- **Right time to switch:** when we ship the `fs.*` JS API (column B)
  AND when we refactor the loader to no-longer-leak. Both have to
  happen together for the swap to be clean.

### A8 — Regex

- **zjs:** Direct TRE calls in the regex-engine code path.
- **std/regex:** Wraps the same TRE (POSIX `regex.h`). `Regex::compile`
  + `compile_with_flags` + `match`/`find`/`count`/`split`. Plus static
  helpers.
- **Verdict — keep for now, switch if we touch regex again.** Mostly
  an aesthetic gain: we already share the TRE backing, so the
  performance and behavior are identical. Wrapping through `Regex`
  buys a slightly nicer call surface for our matchers.

### A9 — Number → string formatter

- **zjs:** Custom shortest-round-trip path in `zjs_to_string`. Matches
  ECMA-262 NumberToString.
- **std/string:** No `Number::to_string` equivalent. Closest is the
  `{var}` interpolation path; the algorithm isn't documented as
  spec-equivalent.
- **Verdict — keep.** No std replacement for ECMA-262 NumberToString.

---

## B. We don't have it; stdlib unblocks us

### B1 — `JSON.parse`

- **zjs:** Not implemented (only stringify).
- **std/json:** `JsonValue::parse(json: char*) -> Result<JsonValue*>`.
  Full DOM tree.
- **Verdict — adopt.** Backing for a future `JSON.parse` host fn:
  call `JsonValue::parse`, walk the tree, materialize ZjsValues. The
  one-time tree allocation is a real cost (vs. a direct ZjsValue
  parser) but the win is correctness for free — we avoid hand-rolling
  another spec-detail-prone parser.

### B2 — `crypto.subtle.digest("SHA-256", ...)`

- **zjs:** Not implemented.
- **std/crypto/sha256:** `Sha256::hash(data)` one-shot + `update`/
  `finalize` for streaming. Returns `u8[32]`.
- **Verdict — adopt.** Direct backing for `crypto.subtle.digest`
  (and `digest("SHA-1", …)` from `std/crypto/sha1`). Combined with
  `Hex::encode` from std/encoding for the standard hex-output API
  many libraries use.

### B3 — Real UTF-8 / Unicode

- **zjs:** Strings are treated as byte sequences. `TextEncoder.encode`
  passes bytes through (works for source-text-built strings; can't
  transcode UTF-16 → UTF-8 for synthesized strings). No
  Unicode-aware `String.prototype.toUpperCase` / `toLowerCase`.
- **std/utf8:** `encode(rune, buf*) -> usize`, `decode(data, len,
  consumed*) -> rune`, `is_alpha`/`is_digit`/`is_whitespace`/
  `is_upper`/`is_lower`/`is_valid`, `to_upper`/`to_lower`.
- **std/string:** `to_uppercase()`/`to_lowercase()` rune-aware,
  `utf8_len()`/`utf8_at()`/`runes()`.
- **Verdict — adopt.** This is the right backing for spec-correct
  TextEncoder, real Unicode case mappings, and eventually
  `String.prototype.normalize`. The byte-string model we have works
  for ASCII; std/utf8 unlocks the rest.

### B4 — `BigInt`

- **zjs:** Not implemented; `BigInt` is a stub.
- **std/bigint:** Exists (docs not pulled here yet).
- **Verdict — adopt** when BigInt becomes a priority. Avoids us
  hand-rolling a multi-precision integer.

### B5 — `Math.random`

- **zjs:** Not implemented.
- **std/random:** Right fit — non-crypto PRNG with seed control.
- **Verdict — adopt.** One-line wrapper:
  `Random::new().next_double()`.

### B6 — Future `fs.*` / `path.*` JS APIs

- **zjs:** Not implemented.
- **std/fs** + **std/path:** Cover most of what a node-style `fs`
  module would expose.
- **Verdict — adopt** when we ship that JS surface. The audit is
  pre-decided here; std is the obvious backing.

### B7 — `fetch` body / Phase D.0

- **zjs:** Not implemented (Phase D.0 about to start).
- **std/net/http::fetch + std/net/tcp:** http-only today (no TLS,
  see task #199). `fetch(url) -> Response` is the right shape for the
  v0.1 implementation.
- **Verdict — adopt.** Direct backing. Bridges to our async story via
  worker thread (or zen-c's async/await once that's wired).

### B8 — `WebSocket` / Phase E

- **zjs:** Not implemented.
- **std/net/websocket:** `WebSocket::handshake(stream, key) -> Result<
  WebSocket>` + `recv`/`send`. Per docs, **server-side handshake** —
  client-side connect not documented.
- **Verdict — adopt with caveat.** We're a client (workers connect
  to servers, not host them); need to verify the client-connect path
  exists or build a thin client-handshake wrapper around `TcpStream`.

---

## Summary table

| Item | Verdict | Effort |
|---|---|---|
| A1 base64 atob/btoa | **keep** — web-spec quirks | — |
| A2 URL / URLSearchParams | **keep** — WHATWG specific | — |
| A3 JSON.stringify | **keep** — direct walk wins | — |
| A4 crypto random | **keep** — CSPRNG required | — |
| A5 Date.now | **switch** to `Time::now()` | tiny |
| A5 performance.now | **keep** — sub-ms required | — |
| A6 module path normalize | **keep** — std doesn't canonicalize | — |
| A7 file reading | **defer** — needs loader ownership refactor | medium |
| A8 regex | **keep**, switch if touched | — |
| A9 NumberToString | **keep** — spec-specific | — |
| B1 JSON.parse | **adopt** std/json parse | medium |
| B2 crypto.subtle.digest | **adopt** std/crypto/sha256 + sha1 | medium |
| B3 Real Unicode | **adopt** std/utf8 + std/string runes | medium |
| B4 BigInt | **adopt** when prioritized | large |
| B5 Math.random | **adopt** std/random | tiny |
| B6 fs.* / path.* JS | **adopt** when needed | medium |
| B7 fetch (Phase D.0) | **adopt** std/net/http | medium |
| B8 WebSocket (Phase E) | **adopt with caveat** | medium |

## One actual near-term pick

The only truly cheap switch:

1. **A5: route Date.now through Time::now** — done in commit
   alongside this audit. One-line; std/time's `Time::now()` is exactly
   what spec wants for Date.now (integer ms since epoch). `performance.now`
   stays on `clock_gettime(CLOCK_MONOTONIC)` for sub-ms.

A7 (file reading) LOOKED cheap but isn't, see the entry. Everything
else in column B is "add when we get to that feature," which is the
right time to make the call.

## What this audit didn't cover

- `std/iter` (we have our own iterator protocol — domain mismatch).
- `std/sync` (we're single-threaded; revisit if/when we add workers).
- `std/thread` (same as above; relevant when fetch needs async).
- `std/process` (interesting for a future `process.*` JS API).
- `std/env` (the `process.env` shim would use this).
- `std/io` / `std/string` general utilities (covered above for
  specific use cases).
