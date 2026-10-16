// A product of int32s that is zero with a negative factor is -0.
function mul(a, b) { return a * b; }
console.log(Object.is(mul(0, -5), -0), Object.is(mul(-3, 0), -0), Object.is(mul(0, 0), 0));
console.log(1 / mul(0, -1), 1 / mul(-2, 0), 1 / mul(0, 2), 1 / mul(-2, -0));
var x = 0;
x *= -7;
console.log(Object.is(x, -0));
console.log(mul(3, 4), mul(-3, 4), mul(65536, 65536), mul(-2147483648, -1));
