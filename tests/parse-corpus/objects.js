var o = { a: 1, "b": 2, 3: 3, if: 4, [computed]: 5, shorthand, method() { return 1; },
  async am() { await 1; }, *gm() { yield 1; }, async *agm() {},
  get prop() { return 1; }, set prop(v) {}, get [c]() {}, set [c](v) {},
  get: 1, set: 2, async: 3, get() {}, set(v) {}, async() {},
  ...spread, nested: { deep: { deeper: [1, { x: 2 }] } }, };
var empty = {};
var trailing = { a: 1, };
var { x, y: renamed, z = 1, w: { v }, ...others } = source;
var [p, , q = 2, [r], ...tail] = list;
[a, b] = [b, a];
({ a, b: c } = obj);
