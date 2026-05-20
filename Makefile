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
PLATFORM_SRC     := src/platform/http_apple.m src/platform/ws_apple.m
PLATFORM_OBJS    := $(BUILD_DIR)/http_apple.o $(BUILD_DIR)/ws_apple.o
PLATFORM_LDFLAGS := -framework Foundation -fobjc-arc
PLATFORM_CFLAGS  := -fobjc-arc
else
SHLIB_EXT := so
RPATH_FLAG := -Wl,-rpath,'$$ORIGIN'
PLATFORM_SRC     := src/platform/http_stub.c src/platform/http_async.c src/platform/ws_stub.c
PLATFORM_OBJS    := $(BUILD_DIR)/http_stub.o $(BUILD_DIR)/http_async.o $(BUILD_DIR)/ws_stub.o
PLATFORM_LDFLAGS := -lpthread
PLATFORM_CFLAGS  :=
endif

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

# zc's stdlib include roots (regex via tre lives here). Resolved from
# the zc binary location so `zc` on $PATH continues to work after a
# Zen-c upgrade.
ZC_BIN_DIR := $(shell dirname $$(command -v zc))
ZC_STDLIB_INCS := -I$(ZC_BIN_DIR) -I$(ZC_BIN_DIR)/std/third-party/tre/include

# Warning silencers required for the transpiled C — Zen-c emits patterns
# (unused params on accessor stubs, intentional sign comparisons, etc.)
# that trip default warnings. Matches the set zc passes internally.
ZC_C_WARNS := -Wno-parentheses -Wno-unused-value -Wno-unused-variable \
              -Wno-unused-parameter -Wno-unused-function \
              -Wno-unused-but-set-variable -Wno-sign-compare \
              -Wno-missing-field-initializers \
              -Wno-incompatible-pointer-types-discards-qualifiers

ZC    := zc
CLANG := clang

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
              src/eval.zc src/aot.zc

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

lib: $(LIB)
$(LIB): $(ENGINE_SRC) include/zjs.h | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) -shared $(LIB_SRC) -o $@

# Static archive for embedding (iOS App Store mandates static linking;
# also the small-size path for other embedders).
#
# zc's `--release -c` mode runs stricter analyzers than the `--release
# -shared` path and currently rejects some patterns the shared build
# accepts. Workaround: drive transpile separately, then compile + ar
# ourselves with the same flag set zc would have used.
lib-static: $(LIBA)

$(LIBA_C): $(ENGINE_SRC) include/zjs.h | $(BUILD_DIR)
	$(ZC) transpile $(ZC_FLAGS) $(LIB_SRC) -o $@

$(LIBA_OBJ): $(LIBA_C)
	$(CLANG) -O3 -fPIC -Isrc $(ZC_STDLIB_INCS) $(ZC_C_WARNS) -c $< -o $@

$(BUILD_DIR)/%.o: src/platform/%.m | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC $(PLATFORM_CFLAGS) -Isrc $(ZC_C_WARNS) -c $< -o $@

$(BUILD_DIR)/%.o: src/platform/%.c | $(BUILD_DIR)
	$(CLANG) -O3 -fPIC -Isrc $(ZC_C_WARNS) -c $< -o $@

$(LIBA): $(LIBA_OBJ) $(PLATFORM_OBJS)
	@rm -f $@
	ar rcs $@ $^

cli: $(CLI)
$(CLI): $(CLI_SRC) $(ENGINE_SRC) | $(BUILD_DIR)
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
$(LEXER_TEST): $(LEXER_TEST_SRC) $(ENGINE_SRC) | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) $(LEXER_TEST_SRC) -o $@

parser-test: $(PARSER_TEST)
$(PARSER_TEST): $(PARSER_TEST_SRC) $(ENGINE_SRC) | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) $(PARSER_TEST_SRC) -o $@

interp-test: $(INTERP_TEST)
$(INTERP_TEST): $(INTERP_TEST_SRC) $(ENGINE_SRC) | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) $(INTERP_TEST_SRC) -o $@

test262-runner: $(T262_RUNNER)
$(T262_RUNNER): $(T262_RUNNER_SRC) include/zjs.h $(LIB) | $(BUILD_DIR)
	$(CLANG) -O2 -Wall -Iinclude $(T262_RUNNER_SRC) -L$(BUILD_DIR) -lzjs $(RPATH_FLAG) -o $@

# Run the canonical test262 conformance subset via the Python harness
# (frontmatter-aware, feature-filtered, records history + HTML report).
# Requires test262 at vendor/test262 (clone with --depth=1 from
# https://github.com/tc39/test262). Report lands in docs/conformance/.
test262: cli
	@python3 scripts/test262/run.py --quiet

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

clean:
	rm -rf $(BUILD_DIR)
