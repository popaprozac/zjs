// The runtime keeps the typed arrays' intrinsics, whatever a program
// drops: with no buffer alive to hold ArrayBuffer.prototype and its
// global deleted, a buffer made after collections still has it.
var Kept = Uint8Array;
var Float = Float64Array;
delete globalThis.ArrayBuffer;
delete globalThis.Float64Array;
var floatProto = Object.getPrototypeOf(new Float(1));
gc();
var junk = [];
for (var j = 0; j < 20000; j++) junk.push({ j: j });
gc();
var made = new Kept(2);
console.log(Object.prototype.toString.call(made.buffer), typeof made.buffer.slice, made.buffer.byteLength);
console.log(Object.getPrototypeOf(new Float(1)) === floatProto, new Float(1)[Symbol.toStringTag]);
