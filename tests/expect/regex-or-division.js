// A `/` opens a regular expression where an expression begins and divides
// after a value: after a keyword spelled as a property name (`o.in / 2`),
// after `await` and `yield` as operators, and inside a template's `${}`.
var o = { in: 8, typeof: 6, new: 10 };
console.log(o.in / 2, o.typeof / 3, o?.new / 5, `${o.in / 4}`);
console.log(`${typeof /a/}|${void /b/}|${[/c/].length}`);
function* g() { const t = `${yield /q+/u}`; yield /r/i; }
const it = g();
console.log(it.next().value.flags, it.next("x").value.flags);
async function f() { return `${await /x+/g.source}:${(await /w/m).flags}`; }
f().then((v) => console.log(v));
