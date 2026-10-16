var o = { a: 1, b: undefined };
var arr = [1, 2, 3];
function Ctor() {}
var inst = new Ctor();
var checks = ("a" in o) + ":" + ("b" in o) + ":" + ("c" in o) + ":" + (1 in arr) + ":" + (5 in arr) + ":" + ("length" in arr) + ":" + ("constructor" in inst);
var insts = (inst instanceof Ctor) + ":" + (o instanceof Ctor) + ":" + (arr instanceof Ctor) + ":" + (inst instanceof Object) + ":" + (new Error("x") instanceof TypeError) + ":" + (new TypeError("x") instanceof Error);
var dels = delete o.a;
dels += ":" + ("a" in o) + ":" + o.a + ":" + delete o.zz + ":" + delete arr[1] + ":" + arr.length + ":" + (1 in arr) + ":" + arr[1];
var counts = { n: 1, s: 5 };
counts.n++; ++counts.n; counts["n"]--;
var post = counts.s++;
var logical = { x: 0, y: null, z: 5 };
logical.x ||= 7; logical.y ??= 8; logical.z &&= 9; logical.w ??= 10;
var v = 0; v ||= 3; v &&= v + 1;
var caught = "";
try { "a" in 5; } catch (e) { caught = e.message; }
checks + "|" + insts + "|" + dels + "|" + counts.n + ":" + post + ":" + counts.s + "|" + logical.x + logical.y + logical.z + logical.w + "|" + v + "|" + caught;
