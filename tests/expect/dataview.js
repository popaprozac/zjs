// DataView: construction, both byte orders for every kind, bounds,
// conversions before the buffer is checked, and a buffer detached at
// each point a program can detach it.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function thrown(f) {
  try { f(); return "no throw"; } catch (e) { return e.constructor.name; }
}
function bytes(buffer) { return Array.prototype.slice.call(new Uint8Array(buffer)); }

// Construction.
var buffer = new ArrayBuffer(16);
var whole = new DataView(buffer);
var part = new DataView(buffer, 4, 8);
var tail = new DataView(buffer, 12);
show("views", [whole.byteLength, whole.byteOffset, part.byteLength, part.byteOffset, tail.byteLength, tail.byteOffset, part.buffer === buffer]);
show("edges", [new DataView(buffer, 16).byteLength, new DataView(buffer, 0, 0).byteLength, new DataView(buffer, "2", 3.9).byteLength]);
show("errors", [
  thrown(function () { DataView(buffer); }),
  thrown(function () { new DataView({}); }),
  thrown(function () { new DataView(new Uint8Array(4)); }),
  thrown(function () { new DataView(buffer, 17); }),
  thrown(function () { new DataView(buffer, 8, 9); }),
  thrown(function () { new DataView(buffer, -1); }),
  thrown(function () { new DataView(buffer, 0, -1); }),
]);
show("tag", [Object.prototype.toString.call(whole), whole[Symbol.toStringTag], ArrayBuffer.isView(whole), ArrayBuffer.isView(buffer), DataView.length, DataView.name]);
show("lengths", [DataView.prototype.getInt8.length, DataView.prototype.setInt8.length, DataView.prototype.getFloat64.name, DataView.prototype.setUint16.name]);

// Every kind, big-endian by default, little-endian when asked.
var view = new DataView(new ArrayBuffer(8));
view.setInt16(0, -2);
view.setInt16(2, -2, true);
show("int16", [bytes(view.buffer).slice(0, 4), view.getInt16(0), view.getInt16(2, true), view.getInt16(0, true), view.getUint16(0)]);
view.setUint32(0, 0x12345678);
view.setUint32(4, 0x12345678, true);
show("uint32", [bytes(view.buffer), view.getUint32(0).toString(16), view.getUint32(4, 1).toString(16), view.getInt32(0, true).toString(16)]);
view.setInt8(0, 200);
view.setUint8(1, -1);
show("int8", [view.getInt8(0), view.getUint8(0), view.getInt8(1), view.getUint8(1)]);
view.setInt32(0, -1);
show("int32", [view.getInt32(0), view.getUint32(0), view.getInt16(2), view.getUint8(3)]);
view.setFloat32(0, 1.5);
view.setFloat32(4, 0.1, true);
show("float32", [bytes(view.buffer), view.getFloat32(0), view.getFloat32(4, true), view.getFloat32(4)]);
view.setFloat64(0, Math.PI);
show("float64", [bytes(view.buffer), view.getFloat64(0), view.getFloat64(0, true)]);
view.setFloat64(0, -0, true);
view.setFloat32(0, NaN);
show("specials", [Object.is(new DataView(new Float64Array([-0]).buffer).getFloat64(0, true), -0), view.getFloat32(0) !== view.getFloat32(0)]);
var nanBits = new DataView(new ArrayBuffer(8));
nanBits.setUint32(0, 0x7ff00000);
nanBits.setUint32(4, 1);
show("nan bits", [nanBits.getFloat64(0) !== nanBits.getFloat64(0), typeof nanBits.getFloat64(0)]);
show("conversions", (function () {
  var v = new DataView(new ArrayBuffer(8));
  v.setUint8(0, 300); v.setInt16(2, 40000); v.setUint32(4, -1);
  return [v.getUint8(0), v.getInt16(2), v.getUint32(4), v.getInt8(0, "x")];
})());

// Bounds, indices, and the order of conversions.
show("bounds", [
  thrown(function () { part.getInt32(5); }),
  thrown(function () { part.getFloat64(1); }),
  part.getFloat64(0),
  thrown(function () { part.getInt8(8); }),
  thrown(function () { part.setInt8(-1, 0); }),
  thrown(function () { part.getInt8(Infinity); }),
  part.getInt8("1"),
  part.getInt8(1.9),
  part.getUint8(),
]);
var order = [];
var index = { valueOf: function () { order.push("index"); return 0; } };
var value = { valueOf: function () { order.push("value"); return 1; } };
var little = { valueOf: function () { order.push("little"); return 1; } };
part.setInt16(index, value, little);
show("order", order);
show("bad index first", (function () {
  var log = [];
  var result = thrown(function () { part.setInt8(-1, { valueOf: function () { log.push("value"); return 0; } }); });
  return [result, log.length];
})());

// Detached buffers.
var donor = new ArrayBuffer(8);
var watched = new DataView(donor, 2, 4);
donor.transfer();
show("detached", [
  watched.buffer === donor,
  thrown(function () { return watched.byteLength; }),
  thrown(function () { return watched.byteOffset; }),
  thrown(function () { watched.getInt8(0); }),
  thrown(function () { watched.setInt8(0, 1); }),
  thrown(function () { new DataView(donor); }),
  thrown(function () { watched.getInt8(-1); }),
]);
show("detached by value", (function () {
  var b = new ArrayBuffer(4);
  var v = new DataView(b);
  return thrown(function () { v.setInt8(0, { valueOf: function () { b.transfer(); return 1; } }); });
})());
show("detached by offset", (function () {
  var b = new ArrayBuffer(4);
  return thrown(function () { new DataView(b, { valueOf: function () { b.transfer(); return 0; } }); });
})());
show("detached by prototype", (function () {
  var b = new ArrayBuffer(4);
  var target = Object.defineProperty(function () {}.bind(), "prototype", { get: function () { b.transfer(); return DataView.prototype; } });
  return thrown(function () { Reflect.construct(DataView, [b], target); });
})());
show("not a view", [thrown(function () { DataView.prototype.getInt8.call(new Uint8Array(4), 0); }), thrown(function () { return Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get.call(buffer); })]);

// Views and typed arrays share the bytes; subclasses.
var shared = new ArrayBuffer(4);
new DataView(shared).setUint16(0, 0x0102);
show("shared", [bytes(shared), new Uint16Array(shared)[0]]);
var offsetView = new DataView(new Uint8Array([1, 2, 3, 4]).buffer, 2);
show("offset view", [offsetView.getUint8(0), offsetView.getUint16(0), offsetView.getUint16(0, true)]);
class Bits extends DataView {
  first() { return this.getUint8(0); }
}
var bits = new Bits(new Uint8Array([9, 8]).buffer);
show("subclass", [bits.first(), bits instanceof DataView, Object.getPrototypeOf(bits) === Bits.prototype, bits.byteLength]);
