// Proxy: creation and revocation; the get, set, has and deleteProperty
// traps, each with the checks the specification makes of a trap's answer
// against the target; every other operation reaching the target; a proxy
// as a prototype (the receiver is the object the access began on, and no
// inline cache may stand in for a trap); Reflect.get and Reflect.set
// with a receiver; private names, which never reach a proxy. Each line
// is a label and the value or the error's kind.
function show(label, body) {
  let out;
  try { out = body(); } catch (error) { out = error && error.constructor ? error.constructor.name : String(error); }
  if (typeof out == "symbol") out = out.toString();
  console.log(label + ": " + String(out));
}
const log = [];
function note(...parts) { log.push(parts.map(part => typeof part == "symbol" ? part.toString() : typeof part == "object" && part !== null ? "obj" : String(part)).join(" ")); }
function flush() { const text = log.join(" | "); log.length = 0; return text; }
const frozen = Object.freeze({ k: 1 });
const fixed = {};
Object.defineProperty(fixed, "ro", { value: 1, writable: false, configurable: false });
Object.defineProperty(fixed, "noGet", { set(v) {}, configurable: false });
Object.defineProperty(fixed, "noSet", { get() { return 2; }, configurable: false });
Object.defineProperty(fixed, "soft", { value: 3, writable: false, configurable: true });
const sealed = Object.preventExtensions({ here: 1 });

// Creation.
show("typeof", () => typeof new Proxy({}, {}));
show("call without new", () => Proxy({}, {}));
show("target number", () => new Proxy(1, {}));
show("target null", () => new Proxy(null, {}));
show("handler string", () => new Proxy({}, "h"));
show("handler undefined", () => new Proxy({}));
show("length", () => Proxy.length);
show("name", () => Proxy.name);
show("revocable length", () => Proxy.revocable.length);
show("proxy of proxy", () => new Proxy(new Proxy({ a: 1 }, {}), {}).a);
show("isArray", () => Array.isArray(new Proxy([], {})) + " " + Array.isArray(new Proxy({}, {})) + " " + Array.isArray(new Proxy(new Proxy([], {}), {})));

// No traps: everything reaches the target.
show("forward get", () => new Proxy({ a: 1 }, {}).a);
show("forward set", () => { const t = {}; const p = new Proxy(t, {}); p.a = 2; return t.a; });
show("forward has", () => { const p = new Proxy({ a: 1 }, {}); return ("a" in p) + " " + ("b" in p) + " " + ("toString" in p); });
show("forward delete", () => { const t = { a: 1 }; const p = new Proxy(t, {}); return (delete p.a) + " " + ("a" in t); });
show("forward keys", () => Object.keys(new Proxy({ a: 1, b: 2 }, {})).join());
show("forward for-in", () => { const names = []; for (const name in new Proxy({ a: 1, b: 2 }, {})) names.push(name); return names.join(); });
show("forward JSON", () => JSON.stringify(new Proxy({ a: [1, { b: 2 }] }, {})));
show("forward proto", () => Object.getPrototypeOf(new Proxy([], {})) === Array.prototype);
show("forward instanceof", () => new Proxy(new Map(), {}) instanceof Map);
show("forward hasOwn", () => { const p = new Proxy({ a: 1 }, {}); return Object.hasOwn(p, "a") + " " + Object.hasOwn(p, "toString"); });
show("forward descriptor", () => JSON.stringify(Object.getOwnPropertyDescriptor(new Proxy({ a: 1 }, {}), "a")));
show("forward define", () => { const t = {}; Object.defineProperty(new Proxy(t, {}), "a", { value: 5 }); return t.a; });
show("forward frozen", () => { const p = new Proxy(frozen, {}); return Object.isFrozen(p) + " " + Object.isExtensible(p); });
show("forward preventExtensions", () => { const t = {}; Object.preventExtensions(new Proxy(t, {})); return Object.isExtensible(t); });
show("forward setPrototypeOf", () => { const t = {}; const proto = { inherited: 1 }; Object.setPrototypeOf(new Proxy(t, {}), proto); return t.inherited; });
show("forward getter this", () => { const p = new Proxy({ get me() { return this; } }, {}); return p.me === p; });
show("forward setter this", () => { let seen; const p = new Proxy({ set me(v) { seen = this; } }, {}); p.me = 1; return seen === p; });
show("forward method this", () => { const p = new Proxy({ who() { return this; } }, {}); return p.who() === p; });
show("forward array", () => { const p = new Proxy([1, 2, 3], {}); p.push(4); return p.length + " " + p[3] + " " + p.map(x => x * 2).join() + " " + [...p].join(); });
show("forward symbol key", () => { const s = Symbol("s"); const p = new Proxy({ [s]: 7 }, {}); return p[s]; });
show("forward string target", () => { const p = new Proxy(new String("ab"), {}); return p.length + " " + p[1]; });
show("forward assign", () => JSON.stringify(Object.assign({}, new Proxy({ a: 1, b: 2 }, {}))));
show("forward spread", () => JSON.stringify({ ...new Proxy({ a: 1 }, {}) }));
show("forward entries", () => JSON.stringify(Object.entries(new Proxy({ a: 1 }, {}))));
show("toString tag", () => Object.prototype.toString.call(new Proxy([], {})) + " " + Object.prototype.toString.call(new Proxy({}, {})));
show("String(proxy)", () => String(new Proxy({}, {})) + " " + `${new Proxy([1, 2], {})}`);
show("loose equality", () => { const p = new Proxy({}, {}); return (p == p) + " " + (p === p) + " " + (p == {}); });

// get.
show("get args", () => { const t = { a: 1 }; const p = new Proxy(t, { get(target, key, receiver) { note(target === t, key, receiver === p); return 9; } }); return p.a + " " + flush(); });
show("get index key", () => { const p = new Proxy([], { get(target, key) { return typeof key + ":" + key; } }); return p[0] + " " + p[1.5] + " " + p["x"]; });
show("get symbol key", () => { const p = new Proxy({}, { get(target, key) { return typeof key; } }); return p[Symbol.iterator] + " " + p[Symbol("q")]; });
show("get this is handler", () => { const h = { get() { return this === h; } }; return new Proxy({}, h).x; });
show("get trap read each time", () => { const h = {}; const p = new Proxy({ a: 1 }, h); const first = p.a; h.get = () => 2; const second = p.a; delete h.get; return first + " " + second + " " + p.a; });
show("get trap null", () => new Proxy({ a: 1 }, { get: null }).a);
show("get trap undefined", () => new Proxy({ a: 1 }, { get: undefined }).a);
show("get trap not callable", () => new Proxy({ a: 1 }, { get: 1 }).a);
show("get trap throws", () => new Proxy({}, { get() { throw new RangeError("x"); } }).a);
show("get inherited trap", () => new Proxy({}, Object.create({ get() { return "from proto"; } })).a);
show("get read-only same", () => new Proxy(fixed, { get() { return 1; } }).ro);
show("get read-only other", () => new Proxy(fixed, { get() { return 2; } }).ro);
show("get soft other", () => new Proxy(fixed, { get() { return 2; } }).soft);
show("get no getter undefined", () => new Proxy(fixed, { get() { return undefined; } }).noGet);
show("get no getter value", () => new Proxy(fixed, { get() { return 1; } }).noGet);
show("get with getter value", () => new Proxy(fixed, { get() { return 1; } }).noSet);
show("get NaN same", () => { const t = {}; Object.defineProperty(t, "n", { value: NaN }); return new Proxy(t, { get() { return NaN; } }).n; });
show("get -0 other", () => { const t = {}; Object.defineProperty(t, "z", { value: 0 }); return new Proxy(t, { get() { return -0; } }).z; });
show("get method call", () => new Proxy({}, { get(target, key) { return () => "called " + key; } }).anything());
show("get destructure", () => { const { a, b } = new Proxy({}, { get(target, key) { return key + "!"; } }); return a + b; });
show("get optional chain", () => new Proxy({}, { get() { return undefined; } }).a?.b);
show("get typeof member", () => typeof new Proxy({}, { get() { return 1; } }).x);

// set.
show("set args", () => { const t = {}; const p = new Proxy(t, { set(target, key, value, receiver) { note(target === t, key, value, receiver === p); return true; } }); p.a = 5; return flush() + " " + ("a" in t); });
show("set false sloppy", () => { const p = new Proxy({}, { set() { return false; } }); p.a = 1; return "quiet"; });
show("set false strict", () => { "use strict"; const p = new Proxy({}, { set() { return false; } }); p.a = 1; return "quiet"; });
show("set truthy", () => { "use strict"; const p = new Proxy({}, { set() { return "yes"; } }); p.a = 1; return "ok"; });
show("set value of expression", () => { const p = new Proxy({}, { set() { return true; } }); return (p.a = 7); });
show("set index key", () => { const p = new Proxy([], { set(target, key, value) { note(typeof key, key, value); return true; } }); p[2] = "v"; return flush(); });
show("set compound", () => { const t = { n: 1 }; const p = new Proxy(t, { get(target, key) { note("get", key); return target[key]; }, set(target, key, value) { note("set", key, value); target[key] = value; return true; } }); p.n += 4; p.n++; return flush() + " " + t.n; });
show("set read-only same", () => { "use strict"; new Proxy(fixed, { set() { return true; } }).ro = 1; return "ok"; });
show("set read-only other", () => { "use strict"; new Proxy(fixed, { set() { return true; } }).ro = 2; return "ok"; });
show("set no setter", () => { "use strict"; new Proxy(fixed, { set() { return true; } }).noSet = 2; return "ok"; });
show("set with setter", () => { "use strict"; new Proxy(fixed, { set() { return true; } }).noGet = 2; return "ok"; });
show("set false skips checks", () => { new Proxy(fixed, { set() { return false; } }).ro = 2; return "ok"; });
show("set trap not callable", () => { new Proxy({}, { set: {} }).a = 1; return "ok"; });
show("set array through traps", () => { const p = new Proxy([], { set(target, key, value) { note(key); target[key] = value; return true; } }); p.push("a", "b"); return flush(); });

// has.
show("has args", () => { const t = {}; const p = new Proxy(t, { has(target, key) { note(target === t, key); return true; } }); return ("a" in p) + " " + (1 in p) + " " + flush(); });
show("has falsy", () => "a" in new Proxy({ a: 1 }, { has() { return 0; } }));
show("has hides non-configurable", () => "ro" in new Proxy(fixed, { has() { return false; } }));
show("has hides on non-extensible", () => "here" in new Proxy(sealed, { has() { return false; } }));
show("has absent on non-extensible", () => "gone" in new Proxy(sealed, { has() { return false; } }));
show("has shows absent", () => "gone" in new Proxy(sealed, { has() { return true; } }));
show("Reflect.has", () => Reflect.has(new Proxy({}, { has(target, key) { return key == "yes"; } }), "yes"));
show("has with", () => { const p = new Proxy({ a: 1 }, { has(target, key) { note(typeof key == "symbol" ? "symbol" : key); return key in target; } }); const value = Function("p", "with (p) { return a; }")(p); return value + " " + flush(); });

// deleteProperty.
show("delete args", () => { const t = { a: 1 }; const p = new Proxy(t, { deleteProperty(target, key) { note(target === t, key); return true; } }); return (delete p.a) + " " + flush() + " " + ("a" in t); });
show("delete false sloppy", () => delete new Proxy({ a: 1 }, { deleteProperty() { return false; } }).a);
show("delete false strict", () => { "use strict"; return delete new Proxy({ a: 1 }, { deleteProperty() { return false; } }).a; });
show("delete non-configurable", () => delete new Proxy(fixed, { deleteProperty() { return true; } }).ro);
show("delete on non-extensible", () => delete new Proxy(sealed, { deleteProperty() { return true; } }).here);
show("delete absent on non-extensible", () => delete new Proxy(sealed, { deleteProperty() { return true; } }).gone);
show("delete index", () => { const p = new Proxy([1], { deleteProperty(target, key) { note(typeof key, key); return true; } }); delete p[0]; return flush(); });
show("Reflect.deleteProperty", () => Reflect.deleteProperty(new Proxy({}, { deleteProperty() { return 0; } }), "a"));

// A proxy as a prototype.
show("proto get", () => { const p = new Proxy({}, { get(target, key, receiver) { return receiver === child ? "child " + key : "other"; } }); const child = Object.create(p); return child.x; });
show("proto get own wins", () => { const child = Object.create(new Proxy({}, { get() { return "trap"; } })); child.x = "own"; return child.x; });
show("proto set", () => { const p = new Proxy({}, { set(target, key, value, receiver) { note(key, value, receiver === child); return true; } }); const child = Object.create(p); child.x = 1; return flush() + " " + Object.hasOwn(child, "x"); });
show("proto set no trap", () => { const child = Object.create(new Proxy({}, {})); child.x = 1; return Object.hasOwn(child, "x") + " " + child.x; });
show("proto has", () => { const child = Object.create(new Proxy({}, { has(target, key) { return key == "magic"; } })); return ("magic" in child) + " " + ("plain" in child); });
show("proto of array", () => { const list = [1]; Object.setPrototypeOf(list, new Proxy(Array.prototype, { get(target, key, receiver) { note(String(key)); return Reflect.get(target, key, receiver); } })); const mapped = list.map(x => x + 1); return mapped[0] + " " + flush(); });
show("proto repeated reads", () => { let reads = 0; const child = Object.create(new Proxy({}, { get() { reads++; return reads; } })); let last; for (let i = 0; i < 5; i++) last = child.x; return last + " " + reads; });
show("proto replaced after reads", () => { const plain = { v: "plain" }; const child = Object.create(plain); let seen = ""; for (let i = 0; i < 3; i++) seen += child.v + " "; Object.setPrototypeOf(child, new Proxy(plain, { get() { return "trap"; } })); for (let i = 0; i < 3; i++) seen += child.v + " "; return seen; });
show("proto store after cache", () => { const plain = {}; const child = Object.create(plain); function put(o, v) { o.w = v; } const a = Object.create(plain); put(a, 1); put(Object.create(plain), 2); const q = Object.create(new Proxy(plain, { set(target, key, value) { note("set", key, value); return true; } })); put(q, 3); return flush() + " " + Object.hasOwn(q, "w"); });

// In builtins and classes.
show("field on proxy this", () => { const targets = []; class A { constructor() { const t = {}; targets.push(t); return new Proxy(t, {}); } } class B extends A { x = 1; ["y"] = 2; } const b = new B(); return b.x + " " + b.y + " " + targets[0].x + " " + Object.keys(b).join(); });
show("field via set trap", () => { const seen = []; class A { constructor() { return new Proxy(this, { set(t, k, v, r) { seen.push("set " + k); return Reflect.set(t, k, v, r); } }); } } class B extends A { x = 1; constructor() { super(); this.z = 3; } } const b = new B(); return b.x + " " + b.z + " " + seen.join(); });
show("method on proxy this", () => { class A { constructor() { return new Proxy(this, {}); } } class B extends A { m() { return this.v; } v = 4; } return new B().m(); });
show("object literal proto proxy", () => { const o = { __proto__: new Proxy({}, { get(t, k) { return "p:" + String(k); } }), own: 1 }; return o.own + " " + o.other; });
show("concat array proxy", () => [0].concat(new Proxy([1, 2], {})).length);
show("spread array proxy", () => [...new Proxy([1, 2], {})].length + " " + Math.max(...new Proxy([3, 9], {})));
show("Array.from proxy", () => Array.from(new Proxy([1, 2], {})).join() + " " + Array.from(new Proxy({ length: 2, 0: "a", 1: "b" }, {})).join());
show("sort through proxy", () => { const t = [3, 1, 2]; new Proxy(t, {}).sort(); return t.join(); });
show("Object.freeze proxy", () => { const t = { a: 1 }; Object.freeze(new Proxy(t, {})); return Object.isFrozen(t); });
show("WeakMap key", () => { const p = new Proxy({}, {}); const w = new WeakMap([[p, 1]]); return w.get(p) + " " + w.has({}); });
show("Map key identity", () => { const t = {}; const p = new Proxy(t, {}); const m = new Map([[p, "p"], [t, "t"]]); return m.get(p) + m.get(t) + m.size; });
show("in with primitive key", () => { const p = new Proxy({ 1: 1 }, {}); return (1 in p) + " " + (Symbol.iterator in p); });
show("valueOf arithmetic", () => new Proxy({ valueOf() { return 20; } }, {}) + 1);
show("toPrimitive hint", () => `${new Proxy({ [Symbol.toPrimitive](hint) { return hint; } }, {})}`);
show("for-of proxy iterator", () => { let out = ""; for (const v of new Proxy(new Set([1, 2]), { get(t, k) { const v = Reflect.get(t, k); return typeof v == "function" ? v.bind(t) : v; } })) out += v; return out; });
show("getter proto chain", () => { class P { get g() { return this.tag; } } const o = new Proxy(Object.assign(new P(), { tag: "t" }), {}); const child = Object.create(o); child.tag = "c"; return o.g + child.g; });
show("delete then has", () => { const p = new Proxy({ a: 1 }, {}); delete p.a; return "a" in p; });
show("Object.create(proxy) keys", () => { const names = []; for (const k in Object.create(new Proxy({ a: 1 }, {}))) names.push(k); return names.join(); });
show("instanceof proxy proto", () => { function F() {} const o = Object.create(new Proxy(F.prototype, {})); return o instanceof F; });
show("isPrototypeOf", () => { const base = {}; return base.isPrototypeOf(new Proxy(Object.create(base), {})); });
show("proto set strict", () => { "use strict"; const child = Object.create(new Proxy({}, { set() { return true; } })); child.x = 1; return Object.hasOwn(child, "x"); });
show("proto set refused strict", () => { "use strict"; const child = Object.create(new Proxy({}, { set() { return false; } })); child.x = 1; return "quiet"; });

// Reflect with a receiver.
show("Reflect.get receiver", () => { const t = { get me() { return this; } }; const r = {}; return (Reflect.get(t, "me", r) === r) + " " + (Reflect.get(t, "me") === t); });
show("Reflect.get in trap", () => { const t = { name: "t", get me() { return this.name; } }; const p = new Proxy(t, { get(target, key, receiver) { return Reflect.get(target, key, receiver); } }); p.name; return Object.create(p, { name: { value: "child" } }).me; });
show("Reflect.set receiver", () => { const t = { set me(v) { this.got = v; } }; const r = {}; Reflect.set(t, "me", 5, r); return r.got + " " + t.got; });
show("Reflect.set plain receiver", () => { const t = { a: 1 }; const r = {}; const ok = Reflect.set(t, "a", 2, r); return ok + " " + t.a + " " + r.a; });
show("Reflect.set in trap", () => { const t = {}; const p = new Proxy(t, { set(target, key, value, receiver) { return Reflect.set(target, key, value, receiver); } }); p.a = 3; return t.a; });
show("Reflect.set read-only receiver", () => { const r = Object.freeze({ a: 1 }); return Reflect.set({}, "a", 2, r); });

// Revocation.
show("revocable shape", () => { const made = Proxy.revocable({}, {}); return Object.keys(made).join() + " " + typeof made.proxy + " " + typeof made.revoke + " " + made.revoke.length + " '" + made.revoke.name + "'"; });
show("revoke get", () => { const { proxy, revoke } = Proxy.revocable({ a: 1 }, {}); const before = proxy.a; revoke(); return before + " " + proxy.a; });
show("revoke set", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); proxy.a = 1; return "ok"; });
show("revoke has", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); return "a" in proxy; });
show("revoke delete", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); return delete proxy.a; });
show("revoke keys", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); return Object.keys(proxy); });
show("revoke typeof", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); return typeof proxy; });
show("revoke twice", () => { const { proxy, revoke } = Proxy.revocable({}, {}); return revoke() + " " + revoke(); });
show("revoke isArray", () => { const { proxy, revoke } = Proxy.revocable([], {}); revoke(); return Array.isArray(proxy); });
show("revoke in trap", () => { const made = Proxy.revocable({ a: 1 }, { get(target, key) { made.revoke(); return target[key]; } }); return made.proxy.a; });
show("revoke as target", () => { const { proxy, revoke } = Proxy.revocable({}, {}); revoke(); return typeof new Proxy(proxy, {}); });
show("revoke non-object", () => Proxy.revocable(1, {}));

// Private names never reach a proxy.
show("private read", () => { class C { #x = 1; static read(o) { return o.#x; } } return C.read(new Proxy(new C(), { get() { return "trap"; } })); });
show("private in", () => { class C { #x = 1; static has(o) { return #x in o; } } return C.has(new C()) + " " + C.has(new Proxy(new C(), { has() { return true; } })); });
show("private write", () => { class C { #x = 1; static write(o) { o.#x = 2; } } C.write(new Proxy(new C(), { set() { return true; } })); return "ok"; });
show("private method", () => { class C { #m() { return 1; } static call(o) { return o.#m(); } } return C.call(new Proxy(new C(), {})); });

