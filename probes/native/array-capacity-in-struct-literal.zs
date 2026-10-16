// `Array<T>.withCapacity` may build a struct literal's field. The engine's
// text builder reserves its byte buffer this way.
import console from "std/console";

struct Builder {
  bytes: Array<u8>;
  units: Array<u16>;
}

function builder(capacity: usize): Builder {
  return Builder({ bytes: Array<u8>.withCapacity(capacity), units: Array<u16>() });
}

function main(): i32 {
  let built = builder(8);
  built.bytes.push(1);
  if (built.bytes.capacity < 8 || built.bytes.length != 1) return 1;
  console.log("ok");
  return 0;
}
