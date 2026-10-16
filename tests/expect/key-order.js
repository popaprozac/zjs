// Own keys: array indices ascending, then strings in insertion order, then symbols; after deletes and in dictionary mode.
var out = [];
var s1 = Symbol("s1"), s2 = Symbol("s2");
var o = { b: 1, 10: 1, a: 1, 2: 1, [s1]: 1, "01": 1, 4294967295: 1, 4294967294: 1 };
o[s2] = 2; o.z = 3; o[1] = 4;
out.push(Object.keys(o).join(","), Object.getOwnPropertyNames(o).join(","), Reflect.ownKeys(o).map(String).join(","));
delete o.a; delete o[2];
out.push(Object.keys(o).join(","));
var big = {};
for (var i = 0; i < 80; i++) big["k" + i] = i;
big[5] = "five"; delete big.k3; delete big.k40;
var keys = Object.keys(big);
out.push(keys.length + " " + keys.slice(0, 4).join(",") + " " + keys.slice(-3).join(","));
var forin = []; for (var k in o) forin.push(k); out.push(forin.join(","));
out.push(JSON.stringify(o), JSON.stringify(Object.entries({ x: 1, 3: 2, y: 3 })));
Object.defineProperty(o, "hidden", { value: 1, enumerable: false });
out.push(Object.keys(o).join(","), Object.getOwnPropertyNames(o).join(","));
out.push(Object.assign({}, { q: 1, 0: 2, [s1]: 3 }, { r: 4 })[s1] + " " + Object.keys(Object.assign({}, { q: 1, 0: 2 })).join(","));
class C { constructor() { this.y = 1; this.x = 2; } }
out.push(Object.keys(new C()).join(","), JSON.stringify(new C()));
console.log(out.join("\n"));
