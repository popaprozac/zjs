var o = { b: 1, a: 2, 10: 3, c: 4 };
delete o.a;
o.d = 5;
var keys = "";
for (var k in o) keys += k + ",";
function P() { this.own = 1; }
P.prototype.shared = 2;
var p = new P();
p.mine = 3;
var chain = "";
for (var key in p) chain += key + ",";
var arr = [7, 8, 9];
arr[5] = 1;
arr.extra = true;
var idx = "";
for (var i in arr) idx += i + ",";
var lex = "";
for (let name in { x: 1, y: 2 }) lex += name;
var str = "";
var none = "";
for (var z in 5) none += z;
for (var q in null) none += q;
var sum = 0;
for (var el of [1, 2, 3]) sum += el;
for (const el2 of [10]) sum += el2;
var holder = {};
for (holder.prop in { p: 1 }) {}
keys + "|" + chain + "|" + idx + "|" + lex + "|" + str + "|" + none + "|" + sum + "|" + holder.prop;
