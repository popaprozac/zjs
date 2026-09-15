// A parameter named `self` collides with the lowered receiver in the
// emitted C.
//
// Found writing the ZJS builtins: a function type whose last parameter is
// the host-function cell being called, named `self`. `z check` accepts
// the program; clang rejects the emitted C with "redefinition of parameter
// 'self'" because a method's `this` lowers to a C parameter of that name.
// Same diagnostic-escape class as the backend inference gaps: Z accepts,
// the backend rejects, with no Z source location.
//
// The engine renamed the parameter. The ask is either a Z diagnostic for
// the reserved lowering name or a mangling that keeps user names apart
// from generated ones.
import console from "std/console";

struct Counter {
  total: i32;

  function add(inout this, self: i32): i32 {
    this.total = this.total + self;
    return this.total;
  }
}

function main(): i32 {
  let counter = Counter({ total: 0 });
  if (counter.add(5) != 5) return 1;
  console.log("ok");
  return 0;
}
