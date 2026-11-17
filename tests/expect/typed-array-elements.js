// Typed-array elements read and written by the dispatch loop's own path
// (an int32 index, a number value), in loops so each site runs many times,
// beside the cases it must leave to the property protocol.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function list(ta) { return Array.prototype.slice.call(ta); }

// Every kind written and read back in a loop.
var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
var inputs = [0, 1, -1, 127.5, 128, 255.5, 256, -129, 65535, 2147483648, 0.1, -0, NaN];
kinds.forEach(function (T) {
  var ta = new T(inputs.length);
  for (var i = 0; i < inputs.length; i++) ta[i] = inputs[i];
  var back = [];
  for (var j = 0; j < ta.length; j++) back.push(Object.is(ta[j], -0) ? "-0" : ta[j] !== ta[j] ? "NaN" : ta[j]);
  show(T.name, back);
});

// Indices outside the array read undefined and write nothing; a literal
// index takes the same path.
var small = new Int16Array([10, 20, 30]);
var outside = [];
for (var k = -2; k < 5; k++) outside.push(small[k]);
for (var w = -2; w < 5; w++) small[w] = 7;
show("outside", [JSON.stringify(outside), list(small), small[0], small[2], small[3], small[-1], Object.keys(small).join()]);

// A subarray reads and writes at its offset.
var whole = new Float64Array([1.5, 2.5, 3.5, 4.5, 5.5]);
var middle = whole.subarray(1, 4);
var seen = [];
for (var m = 0; m < 4; m++) seen.push(middle[m]);
for (var n = 0; n < 3; n++) middle[n] = middle[n] * 10;
show("subarray", [JSON.stringify(seen), list(whole)]);

// Values that are not numbers take the property protocol: converted once,
// in order, and a conversion that detaches leaves nothing written.
var calls = 0;
var counted = { valueOf: function () { calls++; return 3; } };
var target = new Uint8Array(2);
for (var c = 0; c < 2; c++) target[c] = counted;
target[0] = "9";
target[1] = true;
show("conversions", [calls, list(target)]);
var donor = new ArrayBuffer(4);
var victim = new Uint8Array(donor);
victim[0] = { valueOf: function () { donor.transfer(); return 5; } };
show("detached by value", [victim.length, victim[0]]);

// A detached buffer: reads are undefined and writes do nothing.
var gone = new Int32Array(new ArrayBuffer(8));
gone[1] = 42;
var before = gone[1];
gone.buffer.transfer();
var after = [];
for (var d = 0; d < 3; d++) { gone[d] = 1; after.push(gone[d]); }
show("detached", [before, JSON.stringify(after), gone.length]);

// A typed array with enough named properties to be a dictionary.
var named = new Uint16Array(4);
for (var p = 0; p < 80; p++) named["p" + p] = p;
for (var q = 0; q < 4; q++) named[q] = q * 1000 + 1;
var read = [];
for (var r = 0; r < 5; r++) read.push(named[r]);
show("dictionary", [JSON.stringify(read), named.p79, named.length]);

// Element reads beside other objects at the same site, and a typed array
// on a prototype chain.
function first(x) { return x[0]; }
var mixed = [first([4]), first(new Uint8Array([5])), first("6"), first({ 0: 7 }), first(new Float32Array([0.5]))];
var child = Object.create(new Int8Array([9, 8]));
show("mixed", [JSON.stringify(mixed), child[0], child[1], child[2]]);

// A sum over a large array: the loop's own path, many times.
var big = new Int32Array(10000);
for (var b = 0; b < big.length; b++) big[b] = b - 5000;
var total = 0;
for (var t = 0; t < big.length; t++) total += big[t];
var bytes = new Uint8Array(1000);
for (var u = 0; u < 1000; u++) bytes[u] = u;
var histogram = new Uint16Array(256);
for (var v = 0; v < 1000; v++) histogram[bytes[v]]++;
show("loops", [total, histogram[0], histogram[255], histogram[231], bytes[999]]);
