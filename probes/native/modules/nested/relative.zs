// The same header, named relative to the module.
import native from "./ticks.h";
export function twiceRelative(n: i32): i32 {
  return native.probe_ticks(n);
}
