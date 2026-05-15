// zjs's minimal test262 harness.
//
// Used in place of test262's harness/{sta.js,assert.js} because those
// files use features (switch, Function.prototype.call,
// Object.prototype.toString, Array.prototype.join) we don't implement
// yet. Defines just enough to satisfy `assert`, `assert.sameValue`,
// `assert.notSameValue`, `assert.throws`, and `Test262Error`.
//
// Tests that need richer harness helpers (e.g. compareArray) will fail
// here and be classified as failing — that's fine, our config skips
// tests with the harness includes we don't support. As the engine
// grows, this shim can be replaced by the real test262 harness.

function Test262Error(message) {
  this.name = "Test262Error";
  this.message = message;
}

function assert(condition, message) {
  if (condition === true) return;
  throw new Test262Error(message || "assert failed");
}

assert._isSameValue = function (a, b) {
  if (a === b) {
    if (a !== 0) return true;
    return 1 / a === 1 / b;
  }
  return a !== a && b !== b;
};

assert.sameValue = function (actual, expected, message) {
  if (assert._isSameValue(actual, expected)) return;
  throw new Test262Error(message || "sameValue failed");
};

assert.notSameValue = function (actual, unexpected, message) {
  if (!assert._isSameValue(actual, unexpected)) return;
  throw new Test262Error(message || "notSameValue failed");
};

assert.throws = function (expectedCtor, fn, message) {
  var threw = false;
  var got = undefined;
  try {
    fn();
  } catch (e) {
    threw = true;
    got = e;
  }
  if (!threw) {
    throw new Test262Error(message || "expected throw");
  }
  if (got instanceof expectedCtor) return;
  // Fall back to constructor.name comparison since instanceof on host
  // errors can be patchy.
  if (got && got.name && expectedCtor && expectedCtor.name &&
      got.name === expectedCtor.name) return;
  throw new Test262Error(message || "wrong error type");
};

// Some tests use Test262Error.thrower as a callback that always throws.
Test262Error.thrower = function (message) {
  throw new Test262Error(message);
};

// $DONOTEVALUATE is called by negative-parse tests at runtime, never
// reached because parse fails first. Provide a stub so the harness
// itself doesn't error if a test references it.
function $DONOTEVALUATE() {
  throw new Test262Error("test should not have been evaluated");
}
