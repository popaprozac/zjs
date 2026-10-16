var m = [];
m.push(Math.abs(-3), Math.floor(-1.5), Math.ceil(1.2), Math.round(2.5), Math.round(-2.5), Math.round(-0.4), Math.trunc(-4.7), Math.sign(-8), Math.sign(0), Math.sqrt(16), Math.cbrt(27), Math.pow(2, 10), Math.pow(1, Infinity), Math.max(1, 5, 3), Math.max(), Math.min(4, -2), Math.min(), Math.max(1, NaN), Math.hypot(3, 4));
m.push(Math.PI, Math.E, Math.LN2, Math.exp(0), Math.log(Math.E), Math.log2(8), Math.log10(1000), Math.sin(0), Math.cos(0), Math.atan2(1, 1), Math.clz32(1), Math.clz32(0), Math.imul(3, 4), Math.imul(0xffffffff, 5), Math.fround(5.5), Math.fround(0.1) === 0.1);
var r = Math.random();
m.push(typeof r, r >= 0 && r < 1, Math.random() !== Math.random());
m.push(Math.abs("-2"), Math.floor(null), Math.max("3", 2), isNaN(Math.sqrt(-1)), Math.log(0), Math.min(0, -0), 1 / Math.min(0, -0), 1 / Math.max(-0, 0), 1 / Math.round(-0.2));
m.join("|");
