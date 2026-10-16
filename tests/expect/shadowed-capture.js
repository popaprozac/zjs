// A block's let, const, or class shadows a binding a nested function
// captures from its enclosing function only inside that block: the
// enclosing binding still lives in an environment the nested function
// reads outside the block.
function readBeforeBlock(x) {
  return function () { var a = x; { const x = 2; a = a + x; } return a; };
}
console.log(readBeforeBlock(1)());

function readAfterBlock(x) {
  return function () { { const x = 2; } return x; };
}
console.log(readAfterBlock(1)());

function outerLet() {
  let x = 1;
  return function () { var a = x; { let x = 2; a = a + x; } return a; };
}
console.log(outerLet()());

function destructured(name) {
  return [1].map(function (c) { if (c === name) { const [name] = [7]; return name; } return 0; });
}
console.log(destructured(1).join());

function loopAndCatch(x) {
  return function () {
    for (let x = 0; x < 2; x++) {}
    try { throw 3; } catch (x) {}
    { class x {} }
    return x;
  };
}
console.log(loopAndCatch(9)());

function shadowedThroughout(x) {
  return function () { let x = 5; return x; };
}
console.log(shadowedThroughout(1)());
