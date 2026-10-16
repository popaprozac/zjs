// Minimal WPT-shaped test harness for the zjs WinterTC MCA conformance
// probes. Mirrors the public-facing subset of web-platform-tests so
// individual probe files read like real WPT tests:
//
//   test(() => { assert_equals(btoa('hi'), 'aGk='); }, 'btoa');
//   promise_test(async () => {
//     const r = await fetch('data:text/plain,hi');
//     assert_equals(await r.text(), 'hi');
//   }, 'fetch data: URL');
//
// At the end of the file, call `__zjs_wintercg_finish()` to flush a
// JSON-encoded summary to stdout that the Python runner parses.

(function () {
  const results = [];     // [{ name, status, message }]
  const pending = [];     // pending promise_test promises
  const STATUS = { PASS: 'pass', FAIL: 'fail', TIMEOUT: 'timeout' };

  function pushResult(name, status, message) {
    results.push({ name, status, message: message || '' });
  }

  function fmt(v) {
    try {
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      if (typeof v === 'string') return JSON.stringify(v);
      if (typeof v === 'number' || typeof v === 'boolean') return String(v);
      if (typeof v === 'bigint') return v.toString() + 'n';
      if (Array.isArray(v)) {
        return '[' + v.slice(0, 5).map(fmt).join(', ') + (v.length > 5 ? ', …' : '') + ']';
      }
      if (typeof v === 'object') {
        return v.constructor && v.constructor.name ? `${v.constructor.name}{…}` : '{…}';
      }
      return String(v);
    } catch (_) { return '<unfmt>'; }
  }

  // --- assert family ---------------------------------------------------

  globalThis.assert_equals = function (actual, expected, message) {
    // Real WPT uses SameValue with a NaN-equal carve-out; that's the
    // semantics we want here too.
    const eq = actual === expected
      || (typeof actual === 'number' && typeof expected === 'number'
          && actual !== actual && expected !== expected);
    if (!eq) {
      throw new Error(
        `assert_equals: expected ${fmt(expected)} but got ${fmt(actual)}` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_not_equals = function (actual, unexpected, message) {
    if (actual === unexpected) {
      throw new Error(
        `assert_not_equals: got ${fmt(actual)} which was disallowed` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_true = function (v, message) {
    if (v !== true) {
      throw new Error(
        `assert_true: expected true, got ${fmt(v)}` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_false = function (v, message) {
    if (v !== false) {
      throw new Error(
        `assert_false: expected false, got ${fmt(v)}` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_array_equals = function (actual, expected, message) {
    if (!Array.isArray(actual) && !(actual && typeof actual.length === 'number')) {
      throw new Error(`assert_array_equals: actual is not array-like (${fmt(actual)})`);
    }
    if (actual.length !== expected.length) {
      throw new Error(
        `assert_array_equals: length ${actual.length} !== ${expected.length}` +
        (message ? ` — ${message}` : '')
      );
    }
    for (let i = 0; i < expected.length; i++) {
      if (actual[i] !== expected[i]) {
        throw new Error(
          `assert_array_equals: [${i}] ${fmt(actual[i])} !== ${fmt(expected[i])}` +
          (message ? ` — ${message}` : '')
        );
      }
    }
  };

  globalThis.assert_throws_js = function (ctor, fn, message) {
    let threw = false, error;
    try { fn(); } catch (e) { threw = true; error = e; }
    if (!threw) {
      throw new Error(
        `assert_throws_js: function did not throw` +
        (message ? ` — ${message}` : '')
      );
    }
    if (ctor && !(error instanceof ctor)) {
      throw new Error(
        `assert_throws_js: threw ${error && error.constructor && error.constructor.name} but expected ${ctor.name}` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_throws_dom = function (name, fn, message) {
    let threw = false, error;
    try { fn(); } catch (e) { threw = true; error = e; }
    if (!threw) {
      throw new Error(
        `assert_throws_dom: function did not throw` +
        (message ? ` — ${message}` : '')
      );
    }
    if (typeof name === 'string' && error && error.name !== name) {
      throw new Error(
        `assert_throws_dom: thrown .name was ${fmt(error.name)} but expected ${fmt(name)}` +
        (message ? ` — ${message}` : '')
      );
    }
  };

  globalThis.assert_unreached = function (message) {
    throw new Error(`assert_unreached${message ? ': ' + message : ''}`);
  };

  // --- test() runners --------------------------------------------------

  globalThis.test = function (fn, name) {
    try {
      fn();
      pushResult(name, STATUS.PASS);
    } catch (e) {
      pushResult(name, STATUS.FAIL, (e && e.message) || String(e));
    }
  };

  globalThis.promise_test = function (fn, name) {
    let p;
    try { p = Promise.resolve(fn()); }
    catch (e) {
      pushResult(name, STATUS.FAIL, (e && e.message) || String(e));
      return;
    }
    pending.push(
      p.then(
        () => pushResult(name, STATUS.PASS),
        (e) => pushResult(name, STATUS.FAIL, (e && e.message) || String(e))
      )
    );
  };

  // --- flush / summary -------------------------------------------------

  globalThis.__zjs_wintercg_finish = async function () {
    // Wait for every pending promise_test to settle.
    if (pending.length > 0) await Promise.all(pending);
    // Emit a sentinel + JSON blob the runner can grep for.
    const totals = results.reduce(
      (acc, r) => (acc[r.status] = (acc[r.status] || 0) + 1, acc),
      { pass: 0, fail: 0, timeout: 0 }
    );
    console.log('@@WINTERCG_RESULTS_BEGIN@@');
    console.log(JSON.stringify({ totals, results }));
    console.log('@@WINTERCG_RESULTS_END@@');
  };
})();
