# zjs build.
#
# Artifacts:
#   build/zjs            — CLI binary (engine compiled in; `eval` and `lex` subcommands)
#   build/libzjs.dylib   — shared library exposing the C ABI in include/zjs.h
#   build/smoke          — pure-C consumer of libzjs, validates the ABI
#   build/lexer_test     — Zen-c lexer test runner
#
# `make test` builds everything and exercises each artifact.

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SHLIB_EXT := dylib
RPATH_FLAG := -Wl,-rpath,@loader_path
else
SHLIB_EXT := so
RPATH_FLAG := -Wl,-rpath,'$$ORIGIN'
endif

BUILD_DIR    := build
LIB          := $(BUILD_DIR)/libzjs.$(SHLIB_EXT)
CLI          := $(BUILD_DIR)/zjs
SMOKE        := $(BUILD_DIR)/smoke
LEXER_TEST   := $(BUILD_DIR)/lexer_test
PARSER_TEST  := $(BUILD_DIR)/parser_test
INTERP_TEST  := $(BUILD_DIR)/interp_test
T262_RUNNER  := $(BUILD_DIR)/test262_runner

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

.PHONY: all lib cli smoke lexer-test parser-test interp-test test test262-runner test262 test262-quick bench bench-compare clean

all: lib cli smoke lexer-test parser-test interp-test

$(BUILD_DIR):
	mkdir -p $@

lib: $(LIB)
$(LIB): $(ENGINE_SRC) include/zjs.h | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) -shared $(LIB_SRC) -o $@

cli: $(CLI)
$(CLI): $(CLI_SRC) $(ENGINE_SRC) | $(BUILD_DIR)
	$(ZC) build $(ZC_FLAGS) $(CLI_SRC) -o $@

smoke: $(SMOKE)
$(SMOKE): $(SMOKE_SRC) include/zjs.h $(LIB) | $(BUILD_DIR)
	$(CLANG) -O0 -g -Wall -Iinclude $(SMOKE_SRC) -L$(BUILD_DIR) -lzjs $(RPATH_FLAG) -o $@

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
	@echo '--- C smoke test ---'
	@$(SMOKE)
	@echo '--- Lexer test ---'
	@$(LEXER_TEST)
	@echo '--- Parser test ---'
	@$(PARSER_TEST)
	@echo '--- Interpreter test ---'
	@$(INTERP_TEST)
	@echo '--- All checks passed ---'

clean:
	rm -rf $(BUILD_DIR)
