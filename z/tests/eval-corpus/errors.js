var log = "";
try { log += "a"; undefined_name; log += "!"; } catch (e) { log += e.name + ":" + e.message; }
try { null.prop; } catch (e) { log += "|" + e.message; }
try { (42)(); } catch (e) { log += "|" + e.name + ":" + e.message; }
try { throw new TypeError("custom"); } catch (err) { log += "|" + err.name + ":" + err.message; }
try { throw { code: 7 }; } catch (thrown) { log += "|" + thrown.code; }
try { throw "plain"; } catch (s) { log += "|" + s + typeof s; }
var e1 = new Error();
var e2 = Error("called");
log += "|" + (e1.message === undefined || e1.message === "") + ":" + e2.message + ":" + e1.name + ":" + (typeof RangeError);
function risky(n) { if (n > 2) throw new RangeError("too big: " + n); return n; }
function guarded(n) { try { return risky(n); } catch (e) { return e.message; } }
log += "|" + guarded(1) + "," + guarded(5);
function unwinds() { risky(9); }
try { unwinds(); } catch (e) { log += "|" + e.name; }
log;
