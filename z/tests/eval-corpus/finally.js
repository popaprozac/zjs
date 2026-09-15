var trace = "";
try { trace += "t"; } finally { trace += "f"; }
try { try { throw 1; } finally { trace += "F"; } } catch (e) { trace += "c" + e; }
try { throw 2; } catch (e) { trace += "C" + e; } finally { trace += "G"; }
function nested() {
  try {
    try { throw "inner"; } catch (e) { throw e + "-rethrown"; } finally { trace += "n"; }
  } catch (outer) { trace += outer; }
  return trace;
}
nested();
var result = "";
try { result = "ok"; } catch (e) { result = "bad"; } finally { result += "!"; }
trace + "|" + result;
