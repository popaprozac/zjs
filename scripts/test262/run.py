#!/usr/bin/env python3
"""
test262 harness assembly and classification for zjsz, the pieces
test262-ab.py and the whole-suite run share:

  - parse_frontmatter: a test's flags, features, includes, negative.
  - load_config / gather_tests / should_skip: the curated subset in
    config.json and its feature, flag, and include skips.
  - execution_modes / assemble / script_directory: each run of a test
    (sloppy and strict unless a flag says otherwise; a module from its own
    file with the harness as a script included first; a dynamic-import
    script beside its file) with sta.js, assert.js, the async and detach
    shims, and its includes prepended.
  - run_one / classify: one run of zjsz (from source, or through bytecode
    files with aot) and its verdict: the exact thrown type and phase for a
    negative test, Test262:AsyncTestComplete for an async one.

Error messages are not checked. test262-fyi.py counts the whole suite by
test262.fyi's rules instead, for a number that compares with other engines.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


# Force UTF-8 on stdout/stderr — Windows's default text encoding
# (cp1252) chokes on the replacement char (�) and other
# non-Latin-1 codepoints that show up in test262 failure messages.
# Python ≥ 3.7 supports `reconfigure`; safe no-op everywhere else.
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

REPO_ROOT  = Path(__file__).resolve().parent.parent.parent
CONFIG     = REPO_ROOT / "scripts" / "test262" / "config.json"

# -----------------------------------------------------------------------------
# Frontmatter parsing.
#
# Each test262 file starts with a YAML-ish block:
#   /*---
#   description: foo
#   flags: [noStrict]
#   features: [Array.prototype.flat, class]
#   includes: [sta.js, assert.js]
#   negative:
#     phase: parse
#     type: SyntaxError
#   ---*/
#
# A list may also be written as block items on the lines after its key
# ("flags:" then "  - noStrict"). We don't pull in a YAML library — the format is regular enough to
# parse with a few regexes for the keys we care about.
# -----------------------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"/\*---\s*\n(.*?)\n---\*/", re.S)

def parse_frontmatter(src: str):
    m = FRONTMATTER_RE.search(src)
    if not m:
        return {}
    body = m.group(1)
    out = {
        "features": [],
        "flags":    [],
        "includes": [],
        "negative": None,
    }

    def parse_list(line):
        # "features: [a, b, c]" or "features: a"
        rest = line.split(":", 1)[1].strip()
        if rest.startswith("["):
            inside = rest.strip("[]")
            return [t.strip() for t in inside.split(",") if t.strip()]
        return [t.strip() for t in rest.split(",") if t.strip()]

    in_negative = False
    # A list key with nothing after the colon: its items follow as YAML
    # block items ("  - noStrict"), as some files write flags and features.
    list_key = None
    for raw_line in body.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            in_negative = False
            list_key = None
            continue
        stripped = line.lstrip()
        if list_key and stripped.startswith("- "):
            out[list_key].append(stripped[2:].strip())
            continue
        list_key = None
        # Track "negative:" multi-line block (phase + type sub-keys).
        if stripped.startswith("negative:"):
            in_negative = True
            out["negative"] = {"phase": None, "type": None}
            tail = stripped.split(":", 1)[1].strip()
            if tail:
                # one-line form: "negative: { phase: parse, type: SyntaxError }"
                t = re.search(r"type:\s*([A-Za-z]+)", tail)
                p = re.search(r"phase:\s*([A-Za-z]+)", tail)
                if t: out["negative"]["type"]  = t.group(1)
                if p: out["negative"]["phase"] = p.group(1)
            continue
        if in_negative and line.startswith((" ", "\t")):
            if "phase:" in stripped:
                out["negative"]["phase"] = stripped.split(":", 1)[1].strip()
            elif "type:"  in stripped:
                out["negative"]["type"]  = stripped.split(":", 1)[1].strip()
            continue
        in_negative = False
        for key in ("features", "flags", "includes"):
            if stripped.startswith(key + ":"):
                out[key] = parse_list(stripped)
                if not out[key]:
                    list_key = key
                break
    return out

# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------

def load_config():
    with open(CONFIG, encoding="utf-8") as f:
        return json.load(f)

def gather_tests(test262_root, cfg, name_filter=None):
    """Return [(rel_path, abs_path)] sorted, optionally filtered by substring."""
    found = []
    for sub in cfg["include"]:
        root = test262_root / sub
        if not root.exists():
            continue
        for p in sorted(root.rglob("*.js")):
            rel = p.relative_to(test262_root)
            if name_filter and name_filter not in str(rel):
                continue
            if "_FIXTURE" in p.name:        # fixture files, not tests
                continue
            found.append((str(rel), p))
    return found

def should_skip(meta, cfg):
    """Return a reason string if the test should be skipped, else None."""
    skip_features = set(cfg.get("skip_features", []))
    skip_flags    = set(cfg.get("skip_flags", []))
    skip_includes = set(cfg.get("skip_includes", []))

    for f in meta.get("features", []):
        if f in skip_features:
            return f"feature:{f}"
    for fl in meta.get("flags", []):
        if fl in skip_flags:
            return f"flag:{fl}"
    for inc in meta.get("includes", []):
        if inc in skip_includes:
            return f"include:{inc}"
    return None

# zjs CLI prints uncaught throws as:
#     zjs: throw: <ErrorTypeName>: <message>
# This regex pulls out the type name for exact-match negative tests.
ZJS_ERROR_TYPE_RE = re.compile(r"^zjs:\s*throw:\s*([A-Za-z][A-Za-z0-9_]*)", re.M)

# Markers in stderr that indicate the throw originated from the parse
# phase (lexer / parser / compiler) rather than runtime evaluation.
PARSE_PHASE_MARKERS = ("parse error", "compile error")

def extract_error_type(stderr: str) -> str:
    m = ZJS_ERROR_TYPE_RE.search(stderr or "")
    return m.group(1) if m else ""

def is_parse_phase_error(stderr: str) -> bool:
    s = stderr or ""
    return any(mk in s for mk in PARSE_PHASE_MARKERS)

def build_source(test262_root, test_src, meta, *, strict_mode: bool):
    """Prepend the harness (shim + listed includes) and, in strict mode,
    a `"use strict";` pragma. The pragma goes BEFORE the harness so the
    whole concatenated source runs in strict mode (matching spec —
    per INTERPRETING.md the directive prefix applies to the entire
    test source, including harness includes).

    raw flag: prepend nothing. The test runs as-is with no assertions
    library and no Test262Error class — typical for tests that exercise
    behavior of the implementation's bare globals.
    """
    flags = set(meta.get("flags", []))
    if "raw" in flags:
        return test_src
    parts = []
    if strict_mode:
        parts.append('"use strict";')
    harness = test262_root / "harness"
    # Always prepend test262's own sta.js + assert.js — the real harness
    # defines Test262Error, the canonical SameValue / throws semantics,
    # NaN / -0 handling, etc. We used a local shim before switch landed
    # (assert.js uses switch internally). assert.throws verifies
    # thrown.constructor against the expected ctor — every
    # *Error.prototype.constructor needs to point back at itself for
    # that to discriminate (we wire that in ctx_init_builtins).
    parts.append((harness / "sta.js").read_text(encoding="utf-8"))
    parts.append((harness / "assert.js").read_text(encoding="utf-8"))
    if "async" in flags:
        # Test262 async protocol: the test completes when print() is
        # called with the magic 'Test262:AsyncTestComplete' line, or
        # fails when 'Test262:AsyncTestFailure:...' is printed. We don't
        # have a host `print`, so install one that throws on the failure
        # signature and otherwise records completion in a side flag the
        # runner can grep for via stdout. The CLI prints flag-state to
        # stdout for us to inspect post-run.
        parts.append(LOCAL_ASYNC_HARNESS)
    if "detachArrayBuffer.js" in meta.get("includes", []):
        # The host hook $DETACHBUFFER asks for, only where it is asked for.
        parts.append(LOCAL_DETACH_HARNESS)
    for inc in meta.get("includes", []):
        if inc in ("sta.js", "assert.js"):
            continue
        f = harness / inc
        if f.exists():
            parts.append(f.read_text(encoding="utf-8"))
    parts.append(test_src)
    return "\n".join(parts)

# $262.detachArrayBuffer for detachArrayBuffer.js: the host detaches by
# transferring the buffer's bytes away (ArrayBuffer.prototype.transfer),
# and a buffer already detached stays as it is.
LOCAL_DETACH_HARNESS = r"""
var $262 = {
  detachArrayBuffer: function (buffer) {
    if (!buffer.detached) buffer.transfer();
  }
};
"""

# Tiny print shim for async-flag tests. The test calls
# print('Test262:AsyncTestComplete') on success; we surface that to
# stdout so the runner can detect it. Failures call
# print('Test262:AsyncTestFailure:<msg>') and we convert to a throw so
# our normal "uncaught throw → fail" path kicks in.
LOCAL_ASYNC_HARNESS = r"""
var __test262_async_done = false;
// IMPORTANT: the failure path must NOT throw. $DONE is almost always
// invoked from inside a .then() callback (e.g. `p.then($DONE, $DONE)`),
// so a throw here becomes an *unhandled promise rejection* — which the
// engine surfaces silently (exit 0, no stdout). That masked every
// failing async test as the generic "never signaled completion" and hid
// its real reason. Instead, record the verdict to stdout and let the
// runner classify. $DONE is made idempotent so the first verdict wins
// (matches the spec's "first call decides" intent the throw used to
// enforce by aborting the chain).
function print(msg) {
  if (typeof msg === 'string' &&
      (msg.indexOf('Test262:AsyncTestFailure:') === 0 ||
       msg === 'Test262:AsyncTestComplete')) {
    if (msg === 'Test262:AsyncTestComplete') { __test262_async_done = true; }
    try { console.log(msg); } catch (e) {}
    return;
  }
  try { console.log(msg); } catch (e) {}
}
// $DONE: ECMAScript-shaped callback used by promiseHelper.js and
// many async tests in place of print. $DONE() → success;
// $DONE(error) → failure carrying the thrown value.
function $DONE(error) {
  if (__test262_async_done) { return; }   // first verdict wins; no-op after
  if (error) {
    __test262_async_done = true;
    var name = (error && typeof error === 'object' && 'name' in error)
                 ? error.name : 'Test262Error';
    var msg  = (error && typeof error === 'object' && 'message' in error)
                 ? error.message : String(error);
    print('Test262:AsyncTestFailure:' + name + ': ' + msg);
  } else {
    print('Test262:AsyncTestComplete');
  }
}
// A conformant host installs $DONE / print AS GLOBAL-OBJECT PROPERTIES (per
// INTERPRETING.md the async test harness must be able to find $DONE on the
// global). asyncHelpers.js gates `asyncTest` on
// `Object.prototype.hasOwnProperty.call(globalThis, "$DONE")`, so the bare
// function declarations above (which zjs does not currently expose as own
// globalThis properties — a separate engine conformance gap) are not enough.
// Bind them explicitly.
globalThis.$DONE = $DONE;
globalThis.print = print;
"""

def execution_modes(meta):
    """Per INTERPRETING.md §"Strict Mode", each test runs twice (sloppy
    then strict) unless a flag says otherwise:
      - raw:        sloppy only, no harness (handled separately)
      - module:     module code, no strict-prefix transform
      - noStrict:   sloppy only
      - onlyStrict: strict only
    """
    flags = set(meta.get("flags", []))
    if "raw" in flags:    return ["sloppy"]   # raw also skips harness
    if "module" in flags: return ["sloppy"]   # modules implicitly strict; we don't add the pragma
    if "onlyStrict" in flags: return ["strict"]
    if "noStrict" in flags:   return ["sloppy"]
    return ["sloppy", "strict"]

def assemble(test262_root, test_src, meta, test_path, *, strict_mode: bool):
    """What one run of a test is: (source, module_path). A module test
    runs from its own file, so that its relative imports (fixtures, and
    itself) resolve, with the harness as a script included first; any
    other test is its source with the harness prepended."""
    if "module" in set(meta.get("flags", [])):
        return build_source(test262_root, "", meta, strict_mode=False), str(test_path)
    return build_source(test262_root, test_src, meta, strict_mode=strict_mode), None

def script_directory(meta, test_path):
    """Where a script test runs from: beside its own file when it imports
    dynamically, so that its relative specifiers resolve; else anywhere."""
    if "dynamic-import" in set(meta.get("features", [])):
        return os.path.dirname(str(test_path))
    return None

def run_one(zjs_bin, source, timeout_s, aot=False, module_path=None, script_dir=None):
    """Run zjs on the given source. Returns (exit_code, stderr_text, stdout_text).

    In aot mode: compile the source to a .zbc bytecode file first, then
    run THAT instead of the .js. Used by `--aot` to flush out any
    serialization gaps — a regression vs the non-aot run means an op or
    Function field isn't round-tripping correctly.
    """
    # Force UTF-8 on the tempfile — test262 sources are UTF-8, and on
    # Windows the default text-mode encoding (cp1252) chokes on the
    # full Unicode range (arrows, math symbols, etc).
    # newline="" disables universal-newline translation: Windows text
    # mode was rewriting every \n to \r\n, silently feeding the engine
    # CRLF sources the test never contained (string line-continuations
    # `\<LF>` became `\<CR><LF>` and failed to parse).
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                     encoding="utf-8", newline="",
                                     dir=script_dir, prefix=".zjs-") as f:
        f.write(source)
        path = f.name
    zbc_path = path + ".zbc"
    try:
        if module_path is not None:
            # A module: the harness (`source`) runs first as a script.
            # Under --aot each module of the graph is compiled to a module
            # file in an engine of its own and loaded from it.
            via = ["--via-bytecode"] if aot else []
            r = subprocess.run(
                [str(zjs_bin), "run", "--include", path] + via + ["--module", module_path],
                capture_output=True,
                timeout=timeout_s,
            )
            return r.returncode, r.stderr.decode("utf-8", errors="replace"), r.stdout.decode("utf-8", errors="replace")
        if aot:
            # Compile to bytecode. If the compile itself fails (parser
            # error, syntax-error-on-purpose tests, etc.) we still
            # return that as the engine outcome — same shape classify()
            # expects from a runtime throw. The bytecode-eval branch
            # below only runs on successful compile.
            cr = subprocess.run(
                [str(zjs_bin), "compile", path, "-o", zbc_path],
                capture_output=True,
                timeout=timeout_s,
            )
            if cr.returncode != 0:
                return cr.returncode, cr.stderr.decode("utf-8", errors="replace"), \
                       cr.stdout.decode("utf-8", errors="replace")
            run_target = zbc_path
        else:
            run_target = path

        # Capture as bytes so tests with non-UTF8 throws (intentional or
        # accidental) don't blow up the runner's decoder. Decode with
        # errors="replace" to keep classify happy.
        r = subprocess.run(
            [str(zjs_bin), "run", run_target],
            capture_output=True,
            timeout=timeout_s,
        )
        return r.returncode, r.stderr.decode("utf-8", errors="replace"), r.stdout.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT", ""
    finally:
        for p in (path, zbc_path):
            try: os.unlink(p)
            except OSError: pass

def classify(meta, exit_code, stderr, stdout=""):
    """Map (engine outcome, expected outcome) → 'pass' or 'fail (reason)'.

    Negative tests gate on both the error TYPE (exact match against the
    constructor name in the runner's stderr) and the PHASE (parse
    vs runtime — phase: parse requires the throw to come from the
    parser/compiler, not from running code).

    Async-flag tests follow test262's print()-based protocol: the test
    completes when stdout contains 'Test262:AsyncTestComplete'; a
    'Test262:AsyncTestFailure:' prefix or absence of the completion line
    is a failure.
    """
    threw = (exit_code != 0)
    if exit_code == -1:
        return ("fail", "timeout")
    if meta.get("negative"):
        expected_type  = (meta["negative"].get("type")  or "").strip()
        expected_phase = (meta["negative"].get("phase") or "").strip()
        if not threw:
            return ("fail", f"expected {expected_phase or 'any'}-phase throw of {expected_type}, no throw")
        got_type = extract_error_type(stderr)
        if expected_type and got_type != expected_type:
            return ("fail", f"expected {expected_type}, got {got_type or stderr.strip()[:60]}")
        if expected_phase == "parse" and not is_parse_phase_error(stderr):
            return ("fail", f"expected parse-phase {expected_type}, got runtime throw")
        if expected_phase == "runtime" and is_parse_phase_error(stderr):
            return ("fail", f"expected runtime {expected_type}, got parse-phase throw")
        return ("pass", "")
    if "async" in (meta.get("flags") or []):
        if threw:
            return ("fail", stderr.strip()[:120])
        out = stdout or ""
        # The harness now records a failure verdict on stdout instead of
        # throwing it into a swallowed microtask. Surface the real reason.
        fidx = out.find("Test262:AsyncTestFailure:")
        if fidx >= 0:
            line = out[fidx:].splitlines()[0]
            reason = line[len("Test262:AsyncTestFailure:"):].strip()
            return ("fail", ("async: " + reason)[:120])
        if "Test262:AsyncTestComplete" not in out:
            return ("fail", "async test never signaled completion")
        return ("pass", "")
    # Positive test: should not throw.
    if threw:
        return ("fail", stderr.strip()[:120])
    return ("pass", "")
