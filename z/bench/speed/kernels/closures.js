// Creating closures and calling them through captured state.
function counter(start) { var n = start; return function (step) { n += step; return n; }; }
var acc = 0;
for (var i = 0; i < 300000; i++) {
  var c = counter(i);
  acc = (acc + c(1) + c(2)) | 0;
}
var result = acc;
