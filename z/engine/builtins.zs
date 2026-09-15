// The engine with its builtins installed.
//
// Builtins are Z modules under builtins/; each registers its functions
// in the runtime's host table and attaches them to the intrinsic
// prototypes and globals. The runtime module knows nothing of them, so
// they can call back into it -- and through it into JavaScript -- with no
// import cycle.
import { Runtime, createRuntime } from "./runtime.zs";
import { installErrors } from "./builtins/errors.zs";
import { installGlobals } from "./builtins/global.zs";
import { installFunction } from "./builtins/function.zs";
import { installArray } from "./builtins/array.zs";
import { installPrimitives } from "./builtins/primitives.zs";
import { installMath } from "./builtins/math.zs";

export function createEngine(): Runtime {
  let runtime = createRuntime();
  installErrors(inout runtime);
  installFunction(inout runtime);
  installArray(inout runtime);
  installGlobals(inout runtime);
  installPrimitives(inout runtime);
  installMath(inout runtime);
  return runtime;
}
