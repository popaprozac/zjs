# zjs build.
#
# Artifacts:
#   build/zjs            — CLI binary (engine compiled in; `eval` and `lex` subcommands)
#   build/libzjs.dylib   — shared library exposing the C ABI in include/zjs.h
#   build/libzjs.a       — static archive of the same; required for iOS embedding
#   build/smoke          — pure-C consumer of libzjs (dylib), validates the ABI
#   build/smoke_static   — pure-C consumer of libzjs.a, validates static link
#   build/lexer_test     — Zen-c lexer test runner
#
# `make test` builds everything and exercises each artifact.

BUILD_DIR    := build

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SHLIB_EXT := dylib
RPATH_FLAG := -Wl,-rpath,@loader_path
PLATFORM_SRC     := src/platform/http_apple.m src/platform/ws_apple.m src/platform/socket_posix.c
PLATFORM_OBJS    := $(BUILD_DIR)/http_apple.o $(BUILD_DIR)/ws_apple.o $(BUILD_DIR)/socket_posix.o
PLATFORM_LDFLAGS := -framework Foundation -framework Security -fobjc-arc
PLATFORM_CFLAGS  := -fobjc-arc
else
SHLIB_EXT := so
RPATH_FLAG := -Wl,-rpath,'$$ORIGIN'
PLATFORM_SRC     := src/platform/http_linux.c src/platform/http_async.c src/platform/ws_linux.c src/platform/socket_posix.c
PLATFORM_OBJS    := $(BUILD_DIR)/http_linux.o $(BUILD_DIR)/http_async.o $(BUILD_DIR)/ws_linux.o $(BUILD_DIR)/socket_posix.o
PLATFORM_LDFLAGS := -lpthread -lcurl -lwebsockets
PLATFORM_CFLAGS  :=
endif

# Locate zc's stdlib root (the dir containing `std/`). Resolution order:
#   1. $ZC_ROOT if exported (matches the env var zc itself reads)
#   2. The dir holding `zc` on $PATH — works on macOS where the install
#      layout is `<prefix>/zc` next to `<prefix>/std/`
#   3. Linux fallbacks for the standard package layout
# We probe each candidate for `std/third-party/tre/tre_full.c` so a wrong
# guess fails loud instead of producing a half-resolved build.
ZC_ROOT ?= $(shell \
  for d in "$$ZC_ROOT" "$$(dirname $$(command -v zc))" /usr/local/share/zenc /usr/share/zenc; do \
    if [ -n "$$d" ] && [ -f "$$d/std/third-party/tre/tre_full.c" ]; then echo "$$d"; exit 0; fi; \
  done)

# zc reads $ZC_ROOT to decide where to find `std/` and which `-I` paths
# to pass to its backend cc. Export ours so sub-invocations of zc inherit
# the same value the Makefile resolved.
export ZC_ROOT

LIB          := $(BUILD_DIR)/libzjs.$(SHLIB_EXT)
LIBA         := $(BUILD_DIR)/libzjs.a
LIBA_C       := $(BUILD_DIR)/libzjs.c
LIBA_OBJ     := $(BUILD_DIR)/libzjs.o
CLI          := $(BUILD_DIR)/zjs
SMOKE        := $(BUILD_DIR)/smoke
SMOKE_STATIC := $(BUILD_DIR)/smoke_static
LEXER_TEST   := $(BUILD_DIR)/lexer_test
PARSER_TEST  := $(BUILD_DIR)/parser_test
INTERP_TEST  := $(BUILD_DIR)/interp_test
T262_RUNNER  := $(BUILD_DIR)/test262_runner

# zc's stdlib include roots (regex via tre lives here). Driven off
# ZC_ROOT so they track wherever the Zen-c stdlib lives — bin and data
# directories diverge on Linux package layouts.
ifeq ($(ZC_ROOT),)
$(error Could not locate Zen-c stdlib. Set ZC_ROOT to the dir containing `std/` (e.g. /usr/local/share/zenc), or install zc such that its sibling `std/` is discoverable.)
endif
ZC_STDLIB_INCS := -I$(ZC_ROOT) -I$(ZC_ROOT)/std/third-party/tre/include

# Warning silencers required for the transpiled C — Zen-c emits patterns
# (unused params on accessor stubs, intentional sign comparisons, etc.)
# that trip default warnings. Matches the set zc passes internally.
ZC_C_WARNS := -Wno-parentheses -Wno-unused-value -Wno-unused-variable \
              -Wno-unused-parameter -Wno-unused-function \
              -Wno-unused-but-set-variable -Wno-sign-compare \
              -Wno-missing-field-initializers \
              -Wno-incompatible-pointer-types-discards-qualifiers

ZC    := zc
# Variable is historically named CLANG (macOS used `clang` directly), but
# any C/ObjC compiler that understands the flags below works. Default to
# `cc` so Linux gcc-only installs build without an extra dep, while macOS
# (where /usr/bin/cc is clang) keeps the same path.
CLANG ?= cc

# Default to release builds. Until we measured, we were building
# unoptimized — this alone closed ~11× of the perf gap to qjs. To
# build for debugging (no -O, full -g), run `make ZC_FLAGS='-w -O0 -g'`.
ZC_FLAGS := -w --release -Isrc

# Zen-c source files comprising the engine. Every artifact that
# imports src/lib.zc transitively re-imports all of these, so the
# Make rules treat them as a unit.
ENGINE_SRC := src/lib.zc src/context.zc src/value.zc \
              src/token.zc src/lexer.zc \
              src/ast.zc src/parser.zc \
              src/bytecode.zc src/compiler.zc src/interpreter.zc \
              src/eval.zc src/aot.zc \
              src/stdlib/node_path.zc src/stdlib/node_fs.zc \
              src/stdlib/node_process.zc src/stdlib/node_os.zc \
              src/stdlib/node_buffer.zc \
              src/stdlib/node_tty.zc \
              src/stdlib/node_dx.zc \
              src/stdlib/node_stream.zc \
              src/stdlib/node_child_process.zc \
              src/stdlib/node_net.zc src/stdlib/node_http.zc \
              src/stdlib/web_events.zc src/stdlib/web_abort.zc \
              src/stdlib/web_clone.zc src/stdlib/web_blob.zc \
              src/stdlib/web_streams.zc

LIB_SRC         := src/lib.zc
CLI_SRC         := tools/zjs.zc
SMOKE_SRC       := tests/embed_smoke.c
LEXER_TEST_SRC  := tests/lexer_test.zc
PARSER_TEST_SRC := tests/parser_test.zc
INTERP_TEST_SRC := tests/interpreter_test.zc
T262_RUNNER_SRC := tests/test262_runner.c

.PHONY: all lib lib-static cli smoke smoke-static lexer-test parser-test interp-test test test262-runner test262 test262-quick bench bench-compare clean

all: lib lib-static cli smoke smoke-static lexer-test parser-test interp-test

$(BUILD_DIR):
	mkdir -p $@

# zc's stdlib carries `@link("std/third-party/tre/tre_full.c")` in
# std/regex.zc, but zc resolves that path with `realpath()` against the
# *invoking* cwd rather than the stdlib root. With cwd=$(CURDIR) the
# path doesn't exist and gcc fails with:
#   cc1: fatal error: std/third-party/tre/tre_full.c: No such file or directory
# Until that's fixed upstream, point a project-root `std` symlink at
# $(ZC_ROOT)/std so the cwd-relative lookup succeeds. (.gitignored.)
.PHONY: stdlib-link
stdlib-link: std
std:
	@ln -sfn $(ZC_ROOT)/std $@

# Embed .js stdlib sources as C string literals in matching .gen.h
# headers. The .zc files just `#include` the generated header instead
# of carrying inline "..."\n fragments — this gets us syntax
# highlighting, format, lint, and `tsc --check` against zjs-types on
# the JS layer.
#
# Add the .gen.h to the include search path (-Isrc already covers it
# since it lives next to the .js).
STDLIB_JS  := $(wildcard src/stdlib/*.js)
STDLIB_GEN := $(STDLIB_JS:.js=.gen.h)

# Derive the C symbol from the filename: foo_bar.js → FOO_BAR_SOURCE.
src/stdlib/%.gen.h: src/stdlib/%.js tools/embed_js.py
	@python3 tools/embed_js.py $< $@ "$(shell echo $* | tr a-z A-Z)_SOURCE"

.PHONY: stdlib-embed
stdlib-embed: $(STDLIB_GEN)

# Type-check the pure-JS stdlib bootstraps via `tsc --checkJs`. Each
# .js has `// @ts-check` and resolves globals via src/stdlib/_ambient.d.ts.
# Loose typing — the goal is catching typos and undefined-variable
# references, not strict spec compliance against lib.webworker.d.ts
# (we re-implement many of those globals; pulling lib in conflicts).
#
# Run manually:  make stdlib-check
# Requires `npx` / Node + TypeScript.
.PHONY: stdlib-check
stdlib-check: $(STDLIB_JS) src/stdlib/_ambient.d.ts tsconfig.stdlib.json
	@echo "Type-checking stdlib JS via tsc…"
	@npx -y -p typescript@latest tsc -p tsconfig.stdlib.json

lib: $(LIB)
# Depend on PLATFORM_SRC too — zc reads the //> directives in src/lib.zc
# and compiles those .c files in alongside the transpiled engine, but
# Make on its own wouldn't notice a platform-source edit and so wouldn't
# re-run zc. Listing them here forces the rebuild.
$(LIB): $(ENGINE_SRC) $(PLATFORM_SRC) $(STDLIB_GEN) include/zjs.h | $(BUILD_DIR) stdlib-link
	$(ZC) build $(ZC_FLAGS) -shared $(LIB_SRC) -o $@

# Static archive for embedding (iOS App Store mandates static linking;
# also the small-size path for other embedders).
#
# zc's `--release -c` mode runs stricter analyzers than the `--release
# -shared` path and currently rejects some patterns the shared build
# accepts. Workaround: drive transpile separately, then compile + ar
# ourselves with the same flag set zc would have used.
lib-static: $(LIBA)

# --- Tier flags (Phase 2) -----------------------------------------------
# Embedders can drop Ring-1 / Ring-2 stdlib pieces from the build entirely
# (not just at runtime via zjs_new_minimal_context). When a piece is
# excluded here, the install call inside zjs_install_stdlib_extensions is
# preprocessed out, leaving the implementation as unreferenced code that
# the linker's -dead_strip removes function-by-function.
#
# Per-feature flags:
#   ZJS_NO_NODE_MODULES   — drop the `node:` module loader entirely
#   ZJS_NO_WEB_EVENTS     — drop EventTarget / Event / CustomEvent / DOMException
#   ZJS_NO_WEB_ABORT      — drop AbortController / AbortSignal (needs web_events)
#   ZJS_NO_WEB_CLONE      — drop structuredClone
#   ZJS_NO_WEB_BLOB       — drop Blob / File / FormData
#   ZJS_NO_WEB_STREAMS    — drop ReadableStream / WritableStream / TransformStream (largest)
#   ZJS_NO_NODE_NET       — drop node:net host-fn globals
#   ZJS_NO_AOT_WRITER     — drop the bytecode emitter half (reader stays);
#                           zjs_compile_to_bytecode() returns NULL
#
# Presets (each implies the matching ZJS_NO_* set):
#   ZJS_TIER=minimal      — drop everything Ring-1 / Ring-2 + AOT writer (ES core only, reader-only)
#   ZJS_TIER=ring1        — keep web globals, drop node: modules
#   default               — everything
ZJS_TIER ?=
ifeq ($(ZJS_TIER),minimal)
  ZJS_TIER_DEFINES := -DZJS_NO_NODE_MODULES -DZJS_NO_WEB_EVENTS -DZJS_NO_WEB_ABORT \
                     -DZJS_NO_WEB_CLONE -DZJS_NO_WEB_BLOB -DZJS_NO_WEB_STREAMS \
                     -DZJS_NO_NODE_NET -DZJS_NO_AOT_WRITER
else ifeq ($(ZJS_TIER),ring1)
  ZJS_TIER_DEFINES := -DZJS_NO_NODE_MODULES -DZJS_NO_NODE_NET
else
  ZJS_TIER_DEFINES :=
endif
# Per-feature overrides: append any user-set ZJS_NO_* defines.
ZJS_TIER_DEFINES += $(ZJS_FEATURE_DEFINES)

# Per-function / per-data sections so the linker (-dead_strip on Darwin,
# --gc-sections on Linux) can drop the install impls that ZJS_NO_* gated
# out of the call graph. Without this, the whole libzjs.o stays even if
# only one symbol is reachable.
DEADSTRIP_CFLAGS := -ffunction-sections -fdata-sections

# Link-time optimization on by default for release artifacts. Lets the
# linker inline cross-translation-unit, fold duplicates, and prove
# more dead-code-elimination opportunities — saves ~21 KB on minimal
# tier (measured 2026-05-27, docs/binary-size-audit.md). Adds ~1-2s
# to link time on debug iteration, so disable with ZJS_NO_LTO=1 if
# you're rebuilding in a tight inner loop.
ZJS_NO_LTO ?=
ifeq ($(ZJS_NO_LTO),)
  LTO_CFLAGS := -flto=thin
else
  LTO_CFLAGS :=
endif

$(LIBA_C): $(ENGINE_SRC) $(PLATFORM_SRC) include/zjs.h | $(BUILD_DIR) stdlib-link
	$(ZC) transpile $(ZC_FLAGS) $(LIB_SRC) -o $@

$(LIBA_OBJ): $(LIBA_C)
	$(CLANG) -O3 -fPIC -Isrc $(ZC_STDLIB_INCS) $(ZC_C_WARNS) $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS) $(ZJS_TIER_DEFINES) -c $< -o $@

$(BUILD_DIR)/%.o: src/platform/%.m | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC $(PLATFORM_CFLAGS) -Isrc $(ZC_C_WARNS) $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: src/platform/%.c | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC -Isrc $(ZC_C_WARNS) $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS) -c $< -o $@

# QuickJS-NG libregexp (#294) — vendored ECMA-262 regex engine, replaces TRE.
# Three .c files: the regex engine itself, the Unicode tables /
# property tests it depends on, and a tiny shim that supplies the
# three realloc/timeout/stack-check callbacks the library expects from
# the host. CONFIG_ALL_UNICODE turns on the \p{...} property tables.
QJSRE_DIR := src/third-party/qjs-regex
QJSRE_OBJS := $(BUILD_DIR)/qjs_libregexp.o $(BUILD_DIR)/qjs_libunicode.o $(BUILD_DIR)/qjs_regex_shim.o
QJSRE_CFLAGS := -O3 -fPIC -I$(QJSRE_DIR) -DCONFIG_ALL_UNICODE \
                -Wno-parentheses -Wno-unused-value -Wno-unused-variable \
                -Wno-unused-parameter -Wno-unused-function $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS)

$(BUILD_DIR)/qjs_libregexp.o: $(QJSRE_DIR)/libregexp.c $(QJSRE_DIR)/libregexp.h $(QJSRE_DIR)/libregexp-opcode.h | $(BUILD_DIR)
	$(CLANG) $(QJSRE_CFLAGS) -c $< -o $@

$(BUILD_DIR)/qjs_libunicode.o: $(QJSRE_DIR)/libunicode.c $(QJSRE_DIR)/libunicode.h $(QJSRE_DIR)/libunicode-table.h | $(BUILD_DIR)
	$(CLANG) $(QJSRE_CFLAGS) -c $< -o $@

$(BUILD_DIR)/qjs_regex_shim.o: src/platform/qjs_regex_shim.c | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS) -c $< -o $@

# Vendored AES-GCM (crypto.subtle on Apple). The dylib/CLI build pulls
# this in via the `cflags:` directive in src/lib.zc; the static archive
# must compile + bundle the object explicitly or anything linking
# libzjs.a (smoke_static, the test runners) gets undefined
# _zjs_pc_aes_gcm_{encrypt,decrypt}.
AESGCM_DIR := src/third-party/aes-gcm
AESGCM_OBJ := $(BUILD_DIR)/aes_gcm.o
$(AESGCM_OBJ): $(AESGCM_DIR)/aes_gcm.c $(AESGCM_DIR)/aes_gcm.h | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC $(DEADSTRIP_CFLAGS) $(LTO_CFLAGS) -c $< -o $@

$(LIBA): $(LIBA_OBJ) $(PLATFORM_OBJS) $(QJSRE_OBJS) $(AESGCM_OBJ)
	@rm -f $@
	ar rcs $@ $^

cli: $(CLI)
$(CLI): $(CLI_SRC) $(ENGINE_SRC) $(PLATFORM_SRC) $(STDLIB_GEN) | $(BUILD_DIR) stdlib-link
	$(ZC) build $(ZC_FLAGS) $(CLI_SRC) -o $@

smoke: $(SMOKE)
$(SMOKE): $(SMOKE_SRC) include/zjs.h $(LIB) | $(BUILD_DIR)
	$(CLANG) -O0 -g -Wall -Iinclude $(SMOKE_SRC) -L$(BUILD_DIR) -lzjs $(RPATH_FLAG) -o $@

# Same smoke test, but linked against the static archive — proves the .a
# is self-contained and pulls in the platform symbols correctly.
smoke-static: $(SMOKE_STATIC)
$(SMOKE_STATIC): $(SMOKE_SRC) include/zjs.h $(LIBA) | $(BUILD_DIR)
	$(CLANG) -O0 -g -Wall -Iinclude $(SMOKE_SRC) $(LIBA) -lm $(PLATFORM_LDFLAGS) -o $@

lexer-test: $(LEXER_TEST)
$(LEXER_TEST): $(LEXER_TEST_SRC) $(ENGINE_SRC) $(PLATFORM_SRC) | $(BUILD_DIR) stdlib-link
	$(ZC) build $(ZC_FLAGS) $(LEXER_TEST_SRC) -o $@

parser-test: $(PARSER_TEST)
$(PARSER_TEST): $(PARSER_TEST_SRC) $(ENGINE_SRC) $(PLATFORM_SRC) | $(BUILD_DIR) stdlib-link
	$(ZC) build $(ZC_FLAGS) $(PARSER_TEST_SRC) -o $@

interp-test: $(INTERP_TEST)
$(INTERP_TEST): $(INTERP_TEST_SRC) $(ENGINE_SRC) $(PLATFORM_SRC) | $(BUILD_DIR) stdlib-link
	$(ZC) build $(ZC_FLAGS) $(INTERP_TEST_SRC) -o $@

test262-runner: $(T262_RUNNER)
$(T262_RUNNER): $(T262_RUNNER_SRC) include/zjs.h $(LIB) | $(BUILD_DIR)
	$(CLANG) -O2 -Wall -Iinclude $(T262_RUNNER_SRC) -L$(BUILD_DIR) -lzjs $(RPATH_FLAG) -o $@

# WinterTC Minimum Common API conformance. Probes ship in
# tests/wintercg/ — each is a WPT-shaped .js using the harness at
# scripts/wintercg/zjs_harness.js. The runner concatenates harness +
# probe and runs each under ./build/zjs run.
#
# There's no upstream `wintercg/api-test` repo (verified — none of the
# 18 repos in the WinterTC55 org is a test suite). These probes are
# zjs-owned and ratchet over time.
.PHONY: wintercg
wintercg: cli
	@python3 scripts/wintercg/run.py

# Run the canonical test262 conformance subset via the Python harness
# (frontmatter-aware, feature-filtered, records history + HTML report).
# Requires test262 at vendor/test262 (clone with --depth=1 from
# https://github.com/tc39/test262). Report lands in docs/conformance/.
test262: cli
	@python3 scripts/test262/run.py --quiet

# Run the FULL test262 suite (test/language + test/built-ins, no
# feature-skips) for honest absolute-methodology framing — matches
# what test262.fyi reports. Missing-feature failures count as
# failures here, NOT as skips. Does not record to the dashboard.
test262-full: cli
	@python3 scripts/test262/run.py --full-suite --quiet

# End-to-end microbenchmarks. Times each scripts/bench/*.js with
# wall-clock around `zjs run`, records the median, appends history,
# regenerates docs/perf/index.html.
bench: cli
	@python3 scripts/bench/run.py

# Cross-engine comparison: also runs each bench under qjs (jitless,
# our closest peer), node (V8), and bun (JSC). Writes docs/perf/compare.html.
bench-compare: cli
	@python3 scripts/bench/run.py --compare

# Quick C-based runner — older, harness-light, no recording. Useful for
# fast sanity checks against a specific subdir.
T262_DIR ?= vendor/test262/test/language/expressions
test262-quick: test262-runner
	@$(T262_RUNNER) $(T262_DIR)

test: all
	@echo '--- zjs --version ---'
	@$(CLI) --version
	@echo '--- zjs eval "1+1" ---'
	@$(CLI) eval "1+1"
	@echo '--- zjs parse "1 + 2 * 3" ---'
	@$(CLI) parse "1 + 2 * 3"
	@echo '--- zjs parse "let x = 1; if (x) { x = x + 1 }" ---'
	@$(CLI) parse "let x = 1; if (x) { x = x + 1 }"
	@echo '--- zjs parse "function add(a, b) { return a + b; }" ---'
	@$(CLI) parse "function add(a, b) { return a + b; }"
	@echo '--- zjs parse "let inc = x => x + 1;" ---'
	@$(CLI) parse "let inc = x => x + 1;"
	@echo '--- C smoke test (dylib) ---'
	@$(SMOKE)
	@echo '--- C smoke test (static .a) ---'
	@$(SMOKE_STATIC)
	@echo '--- Lexer test ---'
	@$(LEXER_TEST)
	@echo '--- Parser test ---'
	@$(PARSER_TEST)
	@echo '--- Interpreter test ---'
	@$(INTERP_TEST)
	@echo '--- All checks passed ---'

# ============================================================================
# Cross-compile via `zc --cc 'zig cc -target ...'`
#
# zc applies platform directives based on the HOST OS, not the zig
# `-target` flag, so macOS-only directives (`framework: Foundation`,
# the http_apple.m / ws_apple.m cflags) leak through when cross-
# compiling to Linux/Windows from a Mac host (#206).
#
# Workaround: stage a temp tree where the host-incompatible directives
# are sed-stripped out and a target-appropriate set is substituted in.
# zc then sees a single uncontested platform tag, picks it up, and
# delegates the rest to zig cc.
#
# Targets:
#   make cross-linux-arm64
#   make cross-linux-x64
#   make cross-macos-x64      # static, smaller, distributable
#   make cross-all            # all three
#
# Output lands in $(BUILD_DIR)/zjs.<platform>.<arch>.
# ============================================================================

CROSS_DIR := $(BUILD_DIR)/cross-stage

# Renames `//> <other-platform>:` directives to `//> <host>:` in the
# staged tree so zc, which keys off the host OS, applies the cross-
# target's flags. Drops the Apple directives outright when target!=Apple.
#
# Args:
#   $(1) — staging dir (absolute path)
#   $(2) — target host tag to retain ("linux" or "windows" or "macos")
define cross_stage_with_target
	@mkdir -p $(1)
	@rsync -a --delete --exclude=$(BUILD_DIR) --exclude=.git --exclude=vendor \
	  --exclude=docs ./ $(1)/
	@find $(1)/src $(1)/tools $(1)/tests -name '*.zc' -exec sed -i '' \
	    $(if $(filter-out macos,$(2)),-e '/^\/\/> macos:/d' -e '/^\/\/> ios:/d',) \
	    -e 's| -Isrc | -I$(1)/src |g' \
	    -e 's| src/platform/| $(1)/src/platform/|g' \
	    $(if $(filter linux,$(2)),\
	      -e 's| $(1)/src/platform/http_linux.c| $(1)/src/platform/http_stub.c|g' \
	      -e 's| $(1)/src/platform/ws_linux.c| $(1)/src/platform/ws_stub.c|g' \
	      -e 's|-lcurl||g' \
	      -e 's|-lwebsockets||g',) \
	    -e 's|^//> $(2):|//> macos:|g' \
	    {} \;
endef

cross-linux-arm64:
	$(call cross_stage_with_target,$(abspath $(CROSS_DIR)),linux)
	cd $(CROSS_DIR) && zc build --release \
	  --cc 'zig cc -target aarch64-linux-musl -s' \
	  tools/zjs.zc -o $(abspath $(BUILD_DIR))/zjs.linux.arm64
	@ls -la $(BUILD_DIR)/zjs.linux.arm64
	@file $(BUILD_DIR)/zjs.linux.arm64 2>/dev/null | head -1

cross-linux-x64:
	$(call cross_stage_with_target,$(abspath $(CROSS_DIR)),linux)
	cd $(CROSS_DIR) && zc build --release \
	  --cc 'zig cc -target x86_64-linux-musl -s' \
	  tools/zjs.zc -o $(abspath $(BUILD_DIR))/zjs.linux.x64
	@ls -la $(BUILD_DIR)/zjs.linux.x64
	@file $(BUILD_DIR)/zjs.linux.x64 2>/dev/null | head -1

cross-all: cross-linux-arm64 cross-linux-x64
	@echo
	@echo 'Cross builds:'
	@ls -la $(BUILD_DIR)/zjs.linux.arm64 $(BUILD_DIR)/zjs.linux.x64
	@file    $(BUILD_DIR)/zjs.linux.arm64 $(BUILD_DIR)/zjs.linux.x64 2>/dev/null

# cross-macos-x64 deferred — zig cc -target x86_64-macos needs the
# Apple SDK on PATH (Foundation, CommonCrypto, etc.). Native macOS
# users build natively; universal-binary support is a separate
# packaging concern.

# ============================================================================
# iOS cross-compile — produces libzjs.a per arch and a packaged
# zjs.xcframework so an iOS app can drop us in directly.
#
# Targets (all macOS-host only; requires Xcode CLT):
#   make ios-device          # libzjs.a for arm64-apple-ios
#   make ios-simulator       # fat libzjs.a (arm64 + x86_64 simulator)
#   make ios-xcframework     # zjs.xcframework bundling both
#   make ios-all             # alias for ios-xcframework
#
# Output layout under build/ios/:
#   device/libzjs.a          (arm64, iPhoneOS SDK)
#   simulator-arm64/libzjs.a (arm64, iPhoneSimulator SDK)
#   simulator-x64/libzjs.a   (x86_64, iPhoneSimulator SDK)
#   simulator/libzjs.a       (lipo'd fat of the two above)
#   zjs.xcframework/         (drop into Xcode)
#
# Pattern: we run `zc transpile` once to emit C, then drive clang ourselves
# with the right -arch / -isysroot / -m...version-min triple per arch.
# This sidesteps zc's --cc plumbing (which truncates long sysroot paths)
# and zc's link step (Apple ld treats `--static` as unknown). The CLI
# binary isn't built for iOS — apps embed libzjs.a, no shell needed.
# ============================================================================

IOS_DIR     := $(BUILD_DIR)/ios
IOS_MIN     := 15.0
IOS_DEV_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_SIM_SDK := $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)

# Build a libzjs.a for one (arch, sdk, version-min-flag, output dir) tuple.
# Compiles libzjs.c (transpiled) + the Apple platform .m + socket_posix.c
# + libregexp + libunicode + the regex-shim callbacks, then `ar rcs`
# packs them. Each iOS arch gets its own transpile output (cheap;
# deterministic) so concurrent runs don't race.
#
# Args: $(1)=arch  $(2)=sdk path  $(3)=version-min flag  $(4)=output dir
define ios_build_arch
	@mkdir -p $(4)
	@echo "  ios   $(1)  ($(2))"
	$(ZC) transpile $(ZC_FLAGS) $(LIB_SRC) -o $(4)/libzjs.c >/dev/null
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -Isrc $(ZC_STDLIB_INCS) \
	  $(ZC_C_WARNS) -c $(4)/libzjs.c -o $(4)/libzjs.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -fobjc-arc -Isrc \
	  $(ZC_C_WARNS) -c src/platform/http_apple.m -o $(4)/http_apple.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -fobjc-arc -Isrc \
	  $(ZC_C_WARNS) -c src/platform/ws_apple.m -o $(4)/ws_apple.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -Isrc $(ZC_C_WARNS) \
	  -c src/platform/socket_posix.c -o $(4)/socket_posix.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -I$(QJSRE_DIR) \
	  -DCONFIG_ALL_UNICODE $(ZC_C_WARNS) -c $(QJSRE_DIR)/libregexp.c -o $(4)/qjs_libregexp.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -I$(QJSRE_DIR) \
	  -DCONFIG_ALL_UNICODE $(ZC_C_WARNS) -c $(QJSRE_DIR)/libunicode.c -o $(4)/qjs_libunicode.o
	$(CLANG) -O3 -arch $(1) -isysroot $(2) $(3) -Isrc \
	  -c src/platform/qjs_regex_shim.c -o $(4)/qjs_regex_shim.o
	@rm -f $(4)/libzjs.a
	ar rcs $(4)/libzjs.a \
	  $(4)/libzjs.o $(4)/http_apple.o $(4)/ws_apple.o \
	  $(4)/socket_posix.o $(4)/qjs_libregexp.o $(4)/qjs_libunicode.o $(4)/qjs_regex_shim.o
	@file $(4)/libzjs.a
endef

.PHONY: ios-device ios-simulator-arm64 ios-simulator-x64 ios-simulator ios-xcframework ios-all

ios-device:
	@[ -n "$(IOS_DEV_SDK)" ] || \
	  (echo "iPhoneOS SDK not found (xcrun --sdk iphoneos --show-sdk-path)" && exit 1)
	$(call ios_build_arch,arm64,$(IOS_DEV_SDK),-miphoneos-version-min=$(IOS_MIN),$(IOS_DIR)/device)

ios-simulator-arm64:
	@[ -n "$(IOS_SIM_SDK)" ] || \
	  (echo "iPhoneSimulator SDK not found (xcrun --sdk iphonesimulator --show-sdk-path)" && exit 1)
	$(call ios_build_arch,arm64,$(IOS_SIM_SDK),-mios-simulator-version-min=$(IOS_MIN),$(IOS_DIR)/simulator-arm64)

ios-simulator-x64:
	@[ -n "$(IOS_SIM_SDK)" ] || \
	  (echo "iPhoneSimulator SDK not found (xcrun --sdk iphonesimulator --show-sdk-path)" && exit 1)
	$(call ios_build_arch,x86_64,$(IOS_SIM_SDK),-mios-simulator-version-min=$(IOS_MIN),$(IOS_DIR)/simulator-x64)

# Fat lib for the simulator — both arches in one .a so xcframework can
# treat "ios-simulator" as a single slice.
ios-simulator: ios-simulator-arm64 ios-simulator-x64
	@mkdir -p $(IOS_DIR)/simulator
	lipo -create -output $(IOS_DIR)/simulator/libzjs.a \
	  $(IOS_DIR)/simulator-arm64/libzjs.a $(IOS_DIR)/simulator-x64/libzjs.a
	@lipo -info $(IOS_DIR)/simulator/libzjs.a

ios-xcframework: ios-device ios-simulator
	@rm -rf $(IOS_DIR)/zjs.xcframework
	xcodebuild -create-xcframework \
	  -library $(IOS_DIR)/device/libzjs.a -headers include \
	  -library $(IOS_DIR)/simulator/libzjs.a -headers include \
	  -output $(IOS_DIR)/zjs.xcframework
	@echo
	@echo "iOS xcframework: $(IOS_DIR)/zjs.xcframework"
	@ls $(IOS_DIR)/zjs.xcframework/

ios-all: ios-xcframework

clean:
	rm -rf $(BUILD_DIR)
