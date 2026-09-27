# Memory under a large live heap

`large-heap.js` keeps 400,000 small records alive (an object, a string,
and a two-element array each, linked to one another) and then allocates
steady short-lived garbage around them: what a long-running app with a
data model does. It prints its checksum and its own elapsed milliseconds.
What it measures is the peak resident size, which the collector's policy
and layout decide.

```
/usr/bin/time -l z/build/zjsz run --gc-stats --mem-stats z/bench/memory/large-heap.js
```

Peak resident memory, macOS arm64, 2026-09-26 (engine with its young
generation; the engine before it; the others as in `z/bench/speed`):

| Engine | Peak resident |
|---|---|
| zjsz | 117 MB |
| zjsz, one generation | 247 MB |
| QuickJS | 131 MB |
| Hermes 0.13 | 67 MB |
| JavaScriptCore, no JIT | 188 MB |
| V8, jitless | 240 MB |
