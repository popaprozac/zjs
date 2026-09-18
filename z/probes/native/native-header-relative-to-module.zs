// A module in a subdirectory may import a native header beside it by a
// path relative to the module, and a module elsewhere may import it.
import console from "std/console";
import { twiceRelative } from "./modules/nested/relative.zs";
function main(): i32 {
  if (twiceRelative(21) != 42) return 1;
  console.log("ok");
  return 0;
}
