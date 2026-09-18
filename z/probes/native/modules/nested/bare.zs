// A module in a subdirectory names a header beside it by its bare name.
import native from "ticks.h";
export function twiceBare(n: i32): i32 {
  return native.probe_ticks(n);
}
