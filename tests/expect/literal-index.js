// `a[k]` with k an integer literal reads the element in one instruction;
// anything but an array's present element reads as before.
var pair = [10, 20], holey = [1, , 3], nested = [[1, 2], [3, 4]];
console.log(pair[0] + pair[1], holey[1], holey[2], nested[1][0], pair[5], pair[32767]);
Array.prototype[1] = "proto";
console.log(holey[1]);
delete Array.prototype[1];
var str = "hey", like = { 0: "zero", 1: "one" };
var getter = { get 2() { return "got"; } };
console.log(str[1], str[9], like[1], getter[2], (5)[0], true[0]);
try { null[0]; } catch (e) { console.log(e instanceof TypeError); }
try { var u; u[3]; } catch (e) { console.log(e instanceof TypeError); }
var total = 0;
for (var i = 0; i < 1000; i++) { var o = { tags: [i, i + 1] }; total = (total + o.tags[1] + o.tags[0]) | 0; }
console.log(total);
var rows = [[1, 2], [3, 4], [5, 6]];
console.log(rows.map(function (r) { return r[0] * r[1]; }).join(), rows.filter(function (r) { return r[1] > 3; }).length);
var args = (function () { return arguments[1]; })("a", "b");
console.log(args);
