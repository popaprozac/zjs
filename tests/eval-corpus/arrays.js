var list = [10, 20, 30];
list[3] = 40;
list[6] = 70;
var holes = list.length + ":" + list[4] + ":" + typeof list[5];
list.length = 2;
var shrunk = list.length + ":" + list[2] + ":" + list[1];
var big = [];
var i = 0;
while (i < 40) { big[i] = i * i; i = i + 1; }
var text = "" + [1, "two", [3, 4], null, undefined, true];
holes + "|" + shrunk + "|" + big[39] + "|" + big.length + "|" + text + "|" + [] + "|" + [1,2] * 1 + "|" + [7] * 2;
