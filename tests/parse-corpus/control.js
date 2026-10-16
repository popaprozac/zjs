switch (v) { case 1: a(); break; case 2: case 3: b(); default: c(); }
switch (w) {}
try { risky(); } catch (e) { handle(e); }
try { risky(); } catch { recover(); } finally { cleanup(); }
try { risky(); } finally { cleanup(); }
try { risky(); } catch ({ message, code = 0 }) { log(message); }
throw new Error("boom");
throw x, y;
