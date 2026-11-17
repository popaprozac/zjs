// A chain of binds, each link the target of the next. The name of link n
// is 6n units longer than the first target's; kept for every link, the
// names of this chain would take 12 MB.
var f = function () { return 1; };
for (var i = 0; i < 2000; i++) f = f.bind(null);
console.log("chain", f(), f.name.length);
