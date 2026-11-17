// ArrayBuffer and the nine number typed arrays: construction every way,
// element conversions at each kind's edges, the integer-indexed keys
// (canonical numeric strings never reach the prototype), detaching, and
// typed arrays met on another object's prototype chain.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function elements(ta) { return Array.prototype.slice.call(ta); }
function thrown(f) {
  try { f(); return "no throw"; } catch (e) { return e.constructor.name; }
}

// Buffers.
var buffer = new ArrayBuffer(8);
show("buffer", [buffer.byteLength, buffer.detached, buffer.resizable, buffer.maxByteLength, Object.prototype.toString.call(buffer)]);
show("zero", elements(new Uint8Array(buffer)));
show("isView", [ArrayBuffer.isView(buffer), ArrayBuffer.isView(new Int8Array(1)), ArrayBuffer.isView({})]);
show("length coerced", [new ArrayBuffer("3").byteLength, new ArrayBuffer(2.9).byteLength, new ArrayBuffer().byteLength, new ArrayBuffer(NaN).byteLength]);
show("bad length", [thrown(function () { new ArrayBuffer(-1); }), thrown(function () { ArrayBuffer(1); }), thrown(function () { new ArrayBuffer(2 ** 53); })]);
var source = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).buffer;
show("slice", [elements(new Uint8Array(source.slice(2, -3))), source.slice(-2).byteLength, source.slice(5, 2).byteLength, source.slice().byteLength]);

// The nine kinds at their edges.
show("int8", elements(new Int8Array([127, 128, -129, 255, 1.9, -1.9, NaN, Infinity])));
show("uint8", elements(new Uint8Array([256, -1, 1.5, 300.7, -0.5, "7", true, null])));
show("clamped", elements(new Uint8ClampedArray([300, -5, 0.5, 1.5, 2.5, 254.5, 255.5, NaN, -Infinity])));
show("int16", elements(new Int16Array([32767, 32768, -32769, 65535])));
show("uint16", elements(new Uint16Array([65536, -1, 65535.9])));
show("int32", elements(new Int32Array([2147483647, 2147483648, -2147483649, 4294967295])));
show("uint32", elements(new Uint32Array([4294967295, -1, 4294967296 + 5, 2147483648])));
show("float32", elements(new Float32Array([1.5, 0.1, 16777217, 3.4e39, -0])).map(function (v) { return Object.is(v, -0) ? "-0" : v; }));
show("float64", elements(new Float64Array([0.1, -0, 1e308 * 10, NaN])).map(function (v) { return Object.is(v, -0) ? "-0" : v; }));
show("sizes", [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array].map(function (T) {
  return T.name + ":" + T.BYTES_PER_ELEMENT + ":" + T.prototype.BYTES_PER_ELEMENT + ":" + T.length;
}));

// NaN read back from arbitrary bytes is a NaN, whatever its bits.
var nanBytes = new Uint8Array(16);
for (var i = 0; i < 8; i++) nanBytes[i] = 0xff;
nanBytes[8] = 1; nanBytes[14] = 0xf0; nanBytes[15] = 0x7f;
var asFloats = new Float64Array(nanBytes.buffer);
show("nan bits", [asFloats[0] !== asFloats[0], asFloats[1] !== asFloats[1], typeof asFloats[0], new Float32Array(nanBytes.buffer)[0] !== new Float32Array(nanBytes.buffer)[0]]);

// Views on one buffer share its bytes.
var shared = new ArrayBuffer(8);
var bytes = new Uint8Array(shared);
var halves = new Int16Array(shared, 2, 2);
halves[0] = -2;
halves[1] = 0x1234;
show("shared", [elements(bytes), halves.length, halves.byteOffset, halves.byteLength, halves.buffer === shared]);
show("whole buffer", [new Int32Array(shared).length, new Float64Array(shared).length, new Int16Array(shared, 4).length]);
show("view errors", [
  thrown(function () { new Int16Array(new ArrayBuffer(3)); }),
  thrown(function () { new Int32Array(shared, 2); }),
  thrown(function () { new Int32Array(shared, 4, 2); }),
  thrown(function () { new Int8Array(shared, 9); }),
  thrown(function () { new Int8Array(-1); }),
  thrown(function () { Int8Array(1); }),
  thrown(function () { new (Object.getPrototypeOf(Int8Array))(); }),
]);

// From other typed arrays, iterables, and array-likes.
show("from typed", [elements(new Int8Array(new Uint8Array([200, 1]))), elements(new Float64Array(new Int16Array([-3, 4]))), elements(new Uint8Array(new Uint8Array([9, 8]))), elements(new Int16Array(new Int16Array([300, -2, 7]))), elements(new Float64Array(new Float64Array(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]).buffer, 8)))]);
show("from iterable", elements(new Int16Array(new Set([3, 1, 3, 2]))));
function* counted() { yield 1; yield "2"; yield { valueOf: function () { return 3; } }; }
show("from generator", elements(new Float32Array(counted())));
show("from array-like", elements(new Uint8Array({ length: 3, 0: 7, 2: 9 })));

// Keys: canonical numeric strings are elements or nothing.
var keyed = new Uint8Array([10, 20, 30]);
keyed[1.5] = 1; keyed["-0"] = 1; keyed["01"] = 4; keyed[-1] = 2; keyed[3] = 5; keyed.name = "n";
show("keys", [keyed[1.5], keyed["-0"], keyed["01"], keyed[-1], keyed[3], keyed["1"], keyed.name, Object.keys(keyed).join()]);
var forIn = [];
for (var key in keyed) forIn.push(key);
show("for-in", forIn);
show("has", ["1" in keyed, 3 in keyed, "1.5" in keyed, "01" in keyed, keyed.hasOwnProperty(2), keyed.hasOwnProperty(3)]);
show("delete", [delete keyed[0], delete keyed[3], delete keyed["01"], keyed[0]]);
var descriptor = Object.getOwnPropertyDescriptor(keyed, "2");
show("descriptor", [descriptor.value, descriptor.writable, descriptor.enumerable, descriptor.configurable, Object.getOwnPropertyDescriptor(keyed, "3")]);
show("define", [
  Reflect.defineProperty(keyed, 0, { value: 99 }), keyed[0],
  Reflect.defineProperty(keyed, 0, { value: 1, writable: false }),
  Reflect.defineProperty(keyed, 0, { get: function () {} }),
  Reflect.defineProperty(keyed, 5, { value: 1 }),
  thrown(function () { Object.freeze(keyed); }),
]);
show("json", [JSON.stringify(new Int8Array([1, -1])), JSON.stringify({ a: new Uint8Array(2) })]);
show("spread", [[...new Uint16Array([4, 5])].join(), Array.from(new Int8Array([1, 2])).join(), Object.entries(new Uint8Array([7])).join()]);
show("tag", [Object.prototype.toString.call(new Float32Array(1)), new Int8Array(1)[Symbol.toStringTag], Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Int8Array.prototype), Symbol.toStringTag).get.call(3)]);
show("iterators", [[...new Uint8Array([4, 5]).keys()].join(), JSON.stringify([...new Uint8Array([4, 5]).entries()]), new Uint8Array(1)[Symbol.iterator] === Uint8Array.prototype.values]);

// A value is converted once, before the index is checked.
var conversions = 0;
var counting = { valueOf: function () { conversions++; return 1; } };
var small = new Int8Array(1);
small[0] = counting; small[5] = counting; small["x"] = counting;
show("conversions", [conversions, small[0], small.x === counting]);

// Detaching (transfer) leaves the views at length zero.
var donor = new ArrayBuffer(4);
var view = new Uint8Array(donor);
view[0] = 42;
var moved = donor.transfer();
show("transfer", [donor.detached, donor.byteLength, moved.byteLength, new Uint8Array(moved)[0], view.length, view.byteLength, view.byteOffset, view[0]]);
view[0] = 1;
show("detached view", [view[0], 0 in view, Object.keys(view).length, thrown(function () { [...view]; }), thrown(function () { view.values(); })]);
var walking = new ArrayBuffer(3);
var walked = new Uint8Array(walking);
var open = walked.values();
var firstStep = open.next().value;
walking.transfer();
show("detached mid-iteration", [firstStep, thrown(function () { open.next(); })]);
show("detached errors", [thrown(function () { donor.slice(); }), thrown(function () { donor.transfer(); }), thrown(function () { new Int8Array(donor); }), thrown(function () { new Int8Array(view); })]);
var grown = new ArrayBuffer(2);
new Uint8Array(grown)[1] = 7;
show("transfer lengths", [elements(new Uint8Array(grown.transfer(4))), new ArrayBuffer(4).transferToFixedLength(1).byteLength, new ArrayBuffer(3).transfer().byteLength]);

// A typed array on another object's prototype chain.
var parent = new Uint8Array([5, 6]);
var child = Object.create(parent);
Object.prototype[3] = "from Object.prototype";
child[0] = 9;
child[7] = 1;
show("chain", [child[1], child[3], child[0], parent[0], Object.getOwnPropertyNames(child).join(), child.hasOwnProperty(7)]);
delete Object.prototype[3];
var receiver = {};
show("reflect set", [Reflect.set(parent, 1, 8, receiver), receiver[1], parent[1], Reflect.set(parent, 9, 1, receiver), receiver.hasOwnProperty(9), Reflect.set(parent, 0, 1, 1)]);

// Subclasses.
class Bytes extends Uint8Array {
  first() { return this[0]; }
}
var made = new Bytes([7, 8]);
show("subclass", [made.first(), made instanceof Uint8Array, made.length, Object.getPrototypeOf(Bytes) === Uint8Array, Object.getPrototypeOf(Uint8Array) === Object.getPrototypeOf(Int8Array)]);
class Sized extends ArrayBuffer {}
show("buffer subclass", [new Sized(3).byteLength, new Sized(3) instanceof ArrayBuffer, new Sized(4).slice(1).constructor === Sized]);

// Many buffers made and dropped: their bytes are collected.
var kept = 0;
for (var round = 0; round < 300; round++) {
  var chunk = new Uint8Array(65536);
  chunk[65535] = round & 255;
  kept += chunk[65535];
}
show("churn", kept);
