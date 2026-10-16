var obj = {
  value: 7,
  method: function () {
    var arrow = () => this.value * 2;
    var nested = () => () => this.value + 1;
    return arrow() + ":" + nested()()();
  }
};
var add = (a, b) => a + b;
var mul = (a) => (b) => a * b;
var block = (n) => { var s = 0; var i = 0; while (i < n) { s = s + i; i = i + 1; } return s; };
var noArgs = () => "none";
obj.method() + "|" + add(2, 3) + "|" + mul(4)(5) + "|" + block(5) + "|" + noArgs();
