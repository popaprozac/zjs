// Typed arrays read and written by index: a Float64Array filled and
// summed, bytes checksummed in a Uint8Array, an Int32Array prefix sum,
// and a Uint16Array histogram. Each loop reads `length` once, so the
// elements are the work. The work runs in a function, as most code does.
function run() {
  var total = 0;
  var floats = new Float64Array(4096);
  var bytes = new Uint8Array(8192);
  var ints = new Int32Array(4096);
  var counts = new Uint16Array(256);
  for (var round = 0; round < 30; round++) {
    for (var i = 0, fn = floats.length; i < fn; i++) floats[i] = i * 0.5 + round;
    var sum = 0;
    for (var j = 0, jn = floats.length; j < jn; j++) sum += floats[j];
    for (var k = 0, kn = bytes.length; k < kn; k++) bytes[k] = (k * 31 + round) & 255;
    var check = 0;
    for (var m = 0, mn = bytes.length; m < mn; m++) check = (check * 33 + bytes[m]) | 0;
    ints[0] = round;
    for (var n = 1, nn = ints.length; n < nn; n++) ints[n] = (ints[n - 1] + n) | 0;
    for (var p = 0, pn = bytes.length; p < pn; p++) counts[bytes[p]]++;
    total = (total + (sum | 0) + check + ints[ints.length - 1] + counts[7]) | 0;
  }
  return total;
}
var result = run();
