var names = [];
var fn = function () {};
var arrow = () => {};
let lexical = function () {};
const constant = () => 1;
var named = function inner() { return typeof inner; };
var viaParen = (function () {});
var notNamed = (0, function () {});
var reassigned;
reassigned = function () {};
var obj = { method() {}, prop: function () {}, arrowProp: () => 0, get accessor() { return 1; }, set accessor(v) {}, "quoted": function () {} };
function withDefault(cb = function () {}, other = () => 0) { return cb.name + "," + other.name; }
var { destructured = function () {} } = {};
var [fromArray = () => 0] = [];
names.push(fn.name, arrow.name, lexical.name, constant.name, named.name, named(), viaParen.name, notNamed.name);
names.push(obj.method.name, obj.prop.name, obj.arrowProp.name, obj.quoted.name, withDefault(), destructured.name, fromArray.name);
names.push(typeof obj.method.name, (function () {}).name, (() => 0).name);
var caught = "";
try { ({ x() { return x; } }).x(); } catch (e) { caught = e.name; }
names.push(caught, Object.getOwnPropertyDescriptor(fn, "name").writable, fn.hasOwnProperty("name"));
names.join("|");
