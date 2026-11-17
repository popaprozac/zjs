// An array that holds itself reaches its own join again from an
// element's ToString. The specification's steps would never end there;
// engines give the empty string for an object whose join is running.
var a = [1, 2];
a[1] = a;
console.log("[" + a.join() + "]", "[" + String(a) + "]", "[" + a + "]", "[" + a.toString() + "]");
console.log("[" + a.join("-") + "]", "[" + a.toLocaleString() + "]", "[" + `${a}` + "]");

// Through ToNumber: the empty string is 0.
var c = [7];
c[0] = c;
console.log(+c, c == 0);
c++;
console.log(c);

// Holding nothing but itself, and holding itself more than once.
var s = [];
s[0] = s;
console.log("[" + s + "]", s.join("x") === "", "[" + [s, s, 3].join() + "]");
var many = [1];
many.push(many, 2, many);
console.log(many.join("."));

// A cycle through other arrays: each is empty only inside its own join.
var x = ["x"], y = ["y"];
x.push(y);
y.push(x);
console.log(x.join(), "|", y.join(), "|", [x, y].join(";"), "|", String([[x]]));
var p = ["p"], q = ["q"], r = ["r"];
p.push(q);
q.push(r);
r.push(p);
console.log(p.join(), q.join("+"), r.toLocaleString(), [p, q, r].toLocaleString());

// The same array twice is not a cycle.
var t = [1, 2];
console.log([t, t].join(";"), [t, [t], t].join(";"));

// An element whose toString joins the array it sits in, with the array
// as it was and after making every element a primitive.
var m = [1, { toString() { return "<" + m.join("/") + ">"; } }, 3];
console.log(m.join(), m.join());
var n = [1, { toString() { n[1] = 2; return "<" + n.join() + ">"; } }, 3];
console.log(n.join(), n.join());

// The length is read and the separator converted before the inner join
// is found to be running.
var log = [];
var sep = { toString() { log.push("sep"); return "-"; } };
var w = [1, { toString() { log.push("element"); return "<" + w.join(sep) + ">"; } }, 2];
console.log(w.join(sep), log.join());

// An array-like joins the same way.
var like = { length: 3, 0: "l", 2: "r", toString() { return Array.prototype.join.call(this, "~"); } };
like[1] = like;
console.log(Array.prototype.join.call(like), String(like), [like].join());

// A throw from an element midway leaves nothing behind: the next join
// of the same array is a whole one.
var fail = true;
var boom = { toString() { if (fail) throw new Error("boom"); return "ok"; } };
var e = [1, boom];
e.push(e);
try { e.join(); } catch (error) { console.log("caught", error.message); }
try { String(e); } catch (error) { console.log("caught", error.message); }
try { e.toLocaleString(); } catch (error) { console.log("caught", error.message); }
var inner = [boom];
var outer = ["o", inner];
inner.push(outer);
try { outer.join(); } catch (error) { console.log("caught", error.message); }
try { inner.join(); } catch (error) { console.log("caught", error.message); }
fail = false;
console.log(e.join(), "|", String(e), "|", e.toLocaleString());
console.log(outer.join(), "|", inner.join("+"));

// So does a throw from a getter, from a separator, and from a
// toLocaleString that is not a function.
var g = [1, 2, 3];
Object.defineProperty(g, 1, { get() { if (fail) throw new Error("getter"); return g; } });
fail = true;
try { g.join(); } catch (error) { console.log("caught", error.message); }
try { g.join({ toString() { throw new Error("separator"); } }); } catch (error) { console.log("caught", error.message); }
fail = false;
console.log(g.join());
var u = [1, { toLocaleString: 1 }];
u.push(u);
try { u.toLocaleString(); } catch (error) { console.log("caught", error instanceof TypeError); }
console.log(u.join() === "1,[object Object],");

// Deep, but not a cycle.
var deep = ["d"];
for (var i = 0; i < 50; i++) deep = [deep, i];
console.log(deep.join().length, [1, [2, [3, [4]]]].join());
