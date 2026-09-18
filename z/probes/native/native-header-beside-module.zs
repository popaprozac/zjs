// A module in a subdirectory may import a native header beside it by its
// bare name, and a module elsewhere may import that module. The engine's
// Date builtin imports the clock header beside it this way, and the
// runtime two directories up imports the same header by relative path.
import console from "std/console";
import { twiceBare } from "./modules/nested/bare.zs";
function main(): i32 {
  if (twiceBare(21) != 42) return 1;
  console.log("ok");
  return 0;
}
