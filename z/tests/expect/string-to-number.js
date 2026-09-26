// ToNumber of strings and ToString of large integers: the literal
// grammar (white space, signs, the three radix prefixes, Infinity,
// decimal forms), rounding at a double's limits, and integers above 2^53
// printed as their shortest digits.
var log = [];
function show(label, texts) {
  log.push(label + ": " + texts.map(function (text) {
    var n = Number(text);
    return Object.is(n, -0) ? "-0" : String(n);
  }).join(" "));
}
show("space and empty", ["", "  ", " 12 ", "\n\t42\r", " 12", "12 ", "　 7 ﻿", " -3 "]);
show("signs", ["+7", "-7", "-0", "-00", "+0", "-", "+", "--1", "+-1"]);
show("radix", ["0x1F", "0X1f", "0b101", "0B11", "0o17", "0O7", "0x", "0b", "0o", "0b102", "0o8", "0xg", "0x1p3", "0x10.5", "-0x10", "+0x10", " 0x10 ", "0x1_0"]);
show("radix rounding", ["0x1fffffffffffff", "0x20000000000001", "0x20000000000003", "0x3fffffffffffffffffff", "0b" + "1".repeat(70), "0o777777777777777777777", "0x" + "f".repeat(300), "0x" + "1" + "0".repeat(13) + "08"]);
show("infinity", ["Infinity", "+Infinity", "-Infinity", "infinity", "Inf", "inf", "nan", "NaN", "Infinityx", " -Infinity "]);
show("decimal", ["1e3", "1E2", "1e+2", "1e-2", ".5", "5.", "+.5", "-.5", ".", ".e1", "1.e1", "00.5", "007", "0.0", "-0.0", "123.456e-5", "1e", "1e+", "e5", "1_0", "12abc", "1.2.3", "٠"]);
show("decimal limits", ["9007199254740993", "9007199254740992.5", "123456789012345678901234567890", "1.7976931348623157e308", "1.7976931348623159e308", "1e1000", "-1e1000", "4.9e-324", "2.4703282292062328e-324", "1e-400", "-1e-400", "0." + "0".repeat(40) + "1", "1" + "0".repeat(400), "0e999999999", "1e22", "1e23"]);
log.push("large integers: " + [2 ** 53, 2 ** 53 + 2, 2 ** 63, 2 ** 64, 1e21 - 65536, 123456789012345680000, 1e16, 12345678901234567, -(2 ** 70), 5e20, 4.35e20, 999999999999999900000, 1e21].map(String).join(" "));
log.push("unary plus and arithmetic: " + [+"0b11", "0x10" * 1, "1e3" - 0, +" 0o17 ", "2" * "3"].join(" "));
console.log(log.join("\n"));
