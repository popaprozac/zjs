// Resizable ArrayBuffers and the views of them: lengths that track the
// buffer, fixed lengths that fall out of bounds when it shrinks and come
// back when it grows, and resizes in the middle of a method.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function thrown(f) {
  try { f(); return "no throw"; } catch (e) { return e.constructor.name; }
}
function list(ta) { return Array.prototype.slice.call(ta); }

// Construction and the getters.
var rab = new ArrayBuffer(4, { maxByteLength: 16 });
var fixed = new ArrayBuffer(4);
show("getters", [rab.resizable, rab.maxByteLength, rab.byteLength, fixed.resizable, fixed.maxByteLength, new ArrayBuffer(2, {}).resizable, new ArrayBuffer(2, { maxByteLength: undefined }).resizable, new ArrayBuffer(2, 5).resizable]);
var order = [];
var options = { get maxByteLength() { order.push("max"); return 8; } };
new ArrayBuffer({ valueOf: function () { order.push("length"); return 2; } }, options);
show("option order", order);
show("construction errors", [thrown(function () { new ArrayBuffer(5, { maxByteLength: 4 }); }), thrown(function () { new ArrayBuffer(0, { maxByteLength: -1 }); }), thrown(function () { new ArrayBuffer(0, { maxByteLength: 2 ** 53 }); })]);

// resize.
var bytes = new Uint8Array(rab);
bytes.set([1, 2, 3, 4]);
rab.resize(8);
show("grown", [rab.byteLength, bytes.length, list(bytes)]);
rab.resize(2);
show("shrunk", [rab.byteLength, bytes.length, list(bytes)]);
rab.resize(5);
show("regrown", [list(bytes), bytes[4]]);
show("resize errors", [thrown(function () { fixed.resize(2); }), thrown(function () { rab.resize(17); }), thrown(function () { rab.resize(-1); }), thrown(function () { ArrayBuffer.prototype.resize.call({}, 1); })]);

// A length-tracking typed array and a fixed-length one.
var buffer = new ArrayBuffer(8, { maxByteLength: 16 });
var tracking = new Int16Array(buffer, 2);
var window = new Int16Array(buffer, 2, 2);
tracking[0] = 7;
show("in bounds", [tracking.length, tracking.byteLength, tracking.byteOffset, window.length, window[0]]);
buffer.resize(5);
show("window out of bounds", [tracking.length, window.length, window.byteLength, window.byteOffset, window[0], 0 in window, thrown(function () { window.map(function (x) { return x; }); }), thrown(function () { [...window]; }), tracking[0]]);
buffer.resize(1);
show("tracking out of bounds", [tracking.length, tracking.byteOffset, tracking[0], thrown(function () { tracking.join(); }), Object.keys(tracking).length]);
buffer.resize(12);
show("back in bounds", [tracking.length, window.length, window[0], tracking[0]]);

// The dispatch loop's element path with lengths that change between reads.
var loopBuffer = new ArrayBuffer(4, { maxByteLength: 64 });
var loopView = new Uint8Array(loopBuffer);
var seen = [];
for (var round = 0; round < 3; round++) {
  loopBuffer.resize(4 * (round + 1));
  for (var i = 0; i < loopView.length; i++) loopView[i] = i + round;
  var sum = 0;
  for (var j = 0; j < 20; j++) sum += loopView[j] === undefined ? 100 : loopView[j];
  seen.push(loopView.length + ":" + sum);
}
show("loops", seen);

// subarray of a tracking array with no end tracks too.
var subBuffer = new ArrayBuffer(8, { maxByteLength: 16 });
var all = new Uint8Array(subBuffer);
var tail = all.subarray(2);
var cut = all.subarray(2, 4);
subBuffer.resize(12);
show("subarray", [tail.length, cut.length, tail.byteOffset]);

// DataView.
var dvBuffer = new ArrayBuffer(8, { maxByteLength: 16 });
var trackingView = new DataView(dvBuffer, 2);
var fixedView = new DataView(dvBuffer, 2, 4);
trackingView.setUint16(0, 0x0102);
dvBuffer.resize(12);
show("dataview grown", [trackingView.byteLength, fixedView.byteLength, trackingView.getUint16(0)]);
dvBuffer.resize(4);
show("dataview shrunk", [trackingView.byteLength, thrown(function () { return fixedView.byteLength; }), thrown(function () { fixedView.getInt8(0); }), trackingView.getUint8(1)]);
dvBuffer.resize(1);
show("dataview out", [thrown(function () { return trackingView.byteOffset; }), thrown(function () { trackingView.getInt8(0); })]);
var shrinking = new ArrayBuffer(8, { maxByteLength: 8 });
var target = Object.defineProperty(function () {}.bind(), "prototype", { get: function () { shrinking.resize(2); return DataView.prototype; } });
show("dataview constructor", [thrown(function () { Reflect.construct(DataView, [shrinking, 4], target); })]);

// transfer keeps resizability; transferToFixedLength does not.
var donor = new ArrayBuffer(4, { maxByteLength: 8 });
new Uint8Array(donor)[1] = 9;
var moved = donor.transfer();
var movedLonger = moved.transfer(6);
show("transfer", [moved.resizable, moved.maxByteLength, movedLonger.byteLength, movedLonger.resizable, new Uint8Array(movedLonger)[1], movedLonger.transferToFixedLength().resizable, thrown(function () { new ArrayBuffer(1, { maxByteLength: 2 }).transfer(3); })]);
show("slice", (function () {
  var source = new ArrayBuffer(4, { maxByteLength: 8 });
  new Uint8Array(source).set([5, 6, 7, 8]);
  var copy = source.slice(1);
  return [copy.resizable, copy.byteLength, list(new Uint8Array(copy))];
})());

show("slice after a resize", (function () {
  var source = new ArrayBuffer(6, { maxByteLength: 8 });
  new Uint8Array(source).set([1, 2, 3, 4, 5, 6]);
  source.constructor = { [Symbol.species]: function (n) { source.resize(3); return new ArrayBuffer(n); } };
  var copy = source.slice(1);
  return [copy.byteLength, list(new Uint8Array(copy))];
})());

// Typed arrays over resizable buffers cannot be made non-extensible.
var frozenBuffer = new ArrayBuffer(4, { maxByteLength: 8 });
show("freeze", [thrown(function () { Object.freeze(new Uint8Array(frozenBuffer)); }), thrown(function () { Object.preventExtensions(new Uint8Array(frozenBuffer, 0, 2)); }), Reflect.preventExtensions(new Uint8Array(frozenBuffer)), Object.isFrozen(Object.freeze(new Uint8Array(0)))]);

// A resize in the middle of a method.
show("resized by a conversion", (function () {
  var b = new ArrayBuffer(8, { maxByteLength: 8 });
  var fixedLength = new Uint8Array(b, 0, 8);
  var trackingArray = new Uint8Array(b);
  var shrink = { valueOf: function () { b.resize(4); return 1; } };
  var outcome = [thrown(function () { fixedLength.fill(shrink); })];
  b.resize(8);
  trackingArray.fill({ valueOf: function () { b.resize(3); return 2; } });
  outcome.push(list(trackingArray).join(""));
  return outcome;
})());
show("array methods", (function () {
  var b = new ArrayBuffer(3, { maxByteLength: 6 });
  var t = new Uint8Array(b);
  t.set([1, 2, 3]);
  var mapped = Array.prototype.map.call(t, function (x) { return x * 2; });
  b.resize(5);
  return [JSON.stringify(mapped), Array.prototype.join.call(t, "-"), [...t].length];
})());
