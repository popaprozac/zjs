// A struct field's default may call a function imported from another
// module. The compiler's per-function state starts its module record
// with the runtime's emptyModuleInfo() this way.
import console from "std/console";
import { Info, emptyInfo } from "./modules/field-default-maker.zs";

struct Holder {
  count: u32;
  info: Info = emptyInfo();
}

function main(): i32 {
  let holder = Holder({ count: 1 });
  holder.info.names.push(7);
  if (holder.info.names.length != 1) return 1;
  console.log("ok");
  return 0;
}
