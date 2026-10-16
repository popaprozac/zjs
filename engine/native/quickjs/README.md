# QuickJS's regular-expression and Unicode libraries

`libregexp`, `libunicode`, and the `cutils` they rest on, from QuickJS
2026-06-04 (Fabrice Bellard, MIT licence, `LICENSE`), unmodified. The Z
engine's regular expressions run on them through the adapter in
`../zjs_regexp.c`; `native.sh` builds them into `libzjsregexp.a`.

The Zen-c reference keeps its own older copy in `prior-art/zen-c/src/third-party/qjs-regex`.

To update: copy the same files from a QuickJS release, record its version
in `VERSION`, and run `build.sh` and the RegExp and String test262
directories through `test262-ab.py`.
