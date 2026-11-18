// Float16Array, Math.f16round, and DataView's getFloat16 and setFloat16:
// binary16 rounding to nearest with ties to even, from the double itself,
// checked at its edges and over a sweep of values.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
// A binary16 subnormal is printed as its multiple of 2^-24, exactly.
function signed(values) {
  return values.map(function (v) {
    if (Object.is(v, -0)) return "-0";
    if (v !== v) return "NaN";
    if (v !== 0 && Math.abs(v) < 2 ** -14) return v * 2 ** 24 + " x 2^-24";
    return v;
  });
}
function bits(value) {
  var one = new Float16Array([value]);
  return new Uint16Array(one.buffer)[0].toString(16);
}

show("kind", [Float16Array.BYTES_PER_ELEMENT, Float16Array.name, Float16Array.length, Object.getPrototypeOf(Float16Array) === Object.getPrototypeOf(Int8Array), new Float16Array(3).byteLength, Object.prototype.toString.call(new Float16Array(1))]);

// Edges: the largest finite, the overflow point, subnormals, ties, and a
// rounding that carries into the exponent (even and odd).
var edges = [0, -0, 1, -1, 0.1, 1 / 3, 65504, 65519.99, 65520, -65520, 1e10, 2 ** -14, 2 ** -24, 2 ** -25, 3 * 2 ** -25, 2 ** -25 + 2 ** -60, 1.5 * 2 ** -24, 2 ** -14 - 2 ** -25, 1 + 2 ** -11, 1 + 3 * 2 ** -11, 1 + 2 ** -11 + 2 ** -40, 2049, 2051, 4095.9, 8191.9, NaN, Infinity, -Infinity];
show("stored", signed(Array.prototype.slice.call(new Float16Array(edges))));
show("bits", edges.map(bits));
show("f16round", signed(edges.map(Math.f16round)));
show("f16round coerces", signed([Math.f16round("1.5"), Math.f16round(), Math.f16round(null), Math.f16round({ valueOf: function () { return 2.0009765625; } }), Math.f16round.length, Math.f16round.name]));

// A sweep: values across the whole range, from a fixed generator; the
// bits of each are summed.
var seed = 12345;
function next() { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; }
var sweep = new Float64Array(30000);
for (var i = 0; i < sweep.length; i++) {
  var exponent = Math.floor(next() * 50) - 30;
  sweep[i] = (next() - 0.5) * Math.pow(2, exponent);
  if (i % 7 === 0) sweep[i] = (Math.floor(next() * 4096) + 0.5) * Math.pow(2, exponent - 12);
}
var halves = new Float16Array(sweep);
var halfBits = new Uint16Array(halves.buffer);
var checksum = 0;
var rounded = 0;
for (var j = 0; j < halfBits.length; j++) {
  checksum = (checksum * 31 + halfBits[j]) % 1000000007;
  if (Math.f16round(sweep[j]) === halves[j] || (sweep[j] !== sweep[j])) rounded++;
}
show("sweep", [checksum, rounded, halves[0], halves[29999]]);

// DataView in both byte orders.
var view = new DataView(new ArrayBuffer(8));
view.setFloat16(0, 1.5);
view.setFloat16(2, -65504, true);
view.setFloat16(4, 2 ** -24);
view.setFloat16(6, NaN);
show("dataview", [Array.prototype.slice.call(new Uint8Array(view.buffer)), view.getFloat16(0), view.getFloat16(2, true), view.getFloat16(2), signed([view.getFloat16(4)])[0], view.getFloat16(6) !== view.getFloat16(6), DataView.prototype.getFloat16.length, DataView.prototype.setFloat16.length]);

// Methods and conversions between kinds.
var mixed = new Float16Array([3, NaN, -0, 0, -Infinity, 1.0009765625, -1]);
show("sort", signed(Array.prototype.slice.call(mixed.sort())));
show("from float64", signed(Array.prototype.slice.call(Float16Array.from([0.1, 0.2, 0.3]))));
show("to float32", Array.prototype.slice.call(new Float32Array(new Float16Array([0.1, 65504]))));
show("same buffer", (function () {
  var f = new Float16Array([1, 2, 3, 4]);
  f.set(f.subarray(0, 2), 1);
  return Array.prototype.slice.call(f);
})());
show("join", new Float16Array([0.5, 1.25, 1e-7]).join());
