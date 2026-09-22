// Number.prototype.toFixed, toExponential, and toPrecision: exact digits,
// ties rounded to the larger integer, carries, the two layouts, the
// argument coercions, and the errors. Only outcomes are printed.
var log = [];
function kind(f) { try { return String(f()); } catch (e) { return e.constructor.name; } }
function show(label, values) { log.push(label + ": " + values.join(" ")); }
show("fixed ties", [(0.5).toFixed(0), (1.5).toFixed(0), (2.5).toFixed(0), (0.125).toFixed(2), (0.375).toFixed(2), (-2.5).toFixed(0), (-0.5).toFixed(0)]);
show("fixed near", [(1.005).toFixed(2), (1.45).toFixed(1), (8.345).toFixed(2), (9.995).toFixed(2), (0.000001).toFixed(7), (123.456).toFixed(1)]);
show("fixed carry", [(9.5).toFixed(0), (99.95).toFixed(1), (0.95).toFixed(1), (0.05).toFixed(1), (0.005).toFixed(2), (0.0005).toFixed(2), (0.004).toFixed(2)]);
show("fixed zero and big", [(0).toFixed(2), (-0).toFixed(1), (0).toFixed(0), (1e21).toFixed(2), (-1e21).toFixed(0), (123456789012345680000).toFixed(0), (1000000000000000128).toFixed(0), (0.1).toFixed(20)]);
show("fixed args", [(1.5).toFixed(), (1.5).toFixed(undefined), (1.5).toFixed("1"), (1.5).toFixed(1.9), (1.5).toFixed(null), kind(function () { return (1).toFixed(-1); }), kind(function () { return (1).toFixed(101); }), (NaN).toFixed(2), kind(function () { return (Infinity).toFixed(101); }), (Infinity).toFixed(100).length]);
show("exponential", [(123.456).toExponential(), (123.456).toExponential(2), (123.456).toExponential(0), (0).toExponential(), (0).toExponential(2), (-0).toExponential(1), (1e21).toExponential(), (1.1e-7).toExponential(), (0.000001).toExponential(0), (5e-324).toExponential(), (1.7976931348623157e308).toExponential(), (-123.456).toExponential(1)]);
show("exponential ties", [(2.5).toExponential(0), (1.5).toExponential(0), (25).toExponential(0), (35).toExponential(0), (999.5).toExponential(2), (9.5).toExponential(0), (0.125).toExponential(1)]);
show("exponential args", [(123.456).toExponential(0.9), (123.456).toExponential(-0.9), (123.456).toExponential(true), (123.456).toExponential("2"), (123.456).toExponential([]), (123.456).toExponential(NaN), kind(function () { return (1).toExponential(-1); }), kind(function () { return (1).toExponential(101); }), (NaN).toExponential(101), (-Infinity).toExponential(-5), (123456789).toExponential(20)]);
show("precision fixed", [(7).toPrecision(1), (7).toPrecision(3), (-7).toPrecision(2), (10).toPrecision(2), (123.456).toPrecision(4), (123.456).toPrecision(6), (0.000123).toPrecision(2), (0.5).toPrecision(1), (0).toPrecision(1), (0).toPrecision(3), (-0).toPrecision(2), (1).toPrecision(21), (0.1).toPrecision(21)]);
show("precision exponent", [(10).toPrecision(1), (17).toPrecision(1), (100).toPrecision(2), (123.456).toPrecision(2), (0.0000001234).toPrecision(2), (1e21).toPrecision(3), (1e20).toPrecision(3), (123456).toPrecision(3), (1.7976931348623157e308).toPrecision(5), (5e-324).toPrecision(3)]);
show("precision ties", [(2.5).toPrecision(1), (25).toPrecision(1), (35).toPrecision(1), (1.25).toPrecision(2), (1.35).toPrecision(2), (9.995).toPrecision(3), (99.5).toPrecision(2), (999.5).toPrecision(3), (0.95).toPrecision(1)]);
show("precision args", [(123.456).toPrecision(), (123.456).toPrecision(undefined), (123.456).toPrecision("3"), (123.456).toPrecision(2.9), (123.456).toPrecision(true), kind(function () { return (1).toPrecision(0); }), kind(function () { return (1).toPrecision(101); }), kind(function () { return (1).toPrecision(null); }), (NaN).toPrecision(0), (Infinity).toPrecision(101)]);
var calls = 0;
var coercing = { valueOf: function () { calls++; return 2; } };
show("argument evaluated once", [(1.5).toFixed(coercing), (1.5).toExponential(coercing), (1.5).toPrecision(coercing), calls]);
show("receiver", [Number.prototype.toPrecision.call(new Number(4.25), 2), kind(function () { return Number.prototype.toExponential.call("1"); }), kind(function () { return Number.prototype.toPrecision.call({}, 1); }), (5).toPrecision.length, (5).toExponential.length, (5).toExponential.name]);
console.log(log.join("\n"));
