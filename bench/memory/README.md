# Memory under a large live heap

`large-heap.js` keeps 400,000 small records alive (an object, a string,
and a two-element array each, linked to one another) and then allocates
steady short-lived garbage around them: what a long-running app with a
data model does. It prints its checksum and its own elapsed milliseconds.
What it measures is the peak resident size, which the collector's policy
and layout decide.

```
/usr/bin/time -l build/zjsz run --gc-stats --mem-stats bench/memory/large-heap.js
```

The peak depends on the allocator as much as on the engine: run with
`MallocLargeCache=0` in the environment, macOS's allocator stops keeping
freed large blocks resident. The engine's arrays grow by moving, and each
move leaves the old block behind.
