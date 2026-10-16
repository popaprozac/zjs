import console from "std/console";
import {
  Value, fromInt32, toInt32, isInt32,
  fromDouble, toDouble, isDouble,
  fromBoolean, isTruthy,
  fromCell, toCell, isCell,
} from "./value.zs";

function main(): i32 {
  const a = fromInt32(-42);
  const b = fromDouble(3.5);
  const c = fromBoolean(true);
  const d = fromCell(4096);

  console.log(`int   ${toInt32(a)} isInt=${isInt32(a)} isCell=${isCell(a)}`);
  console.log(`double ${toDouble(b)} isDouble=${isDouble(b)} isInt=${isInt32(b)}`);
  console.log(`bool  ${isTruthy(c)}`);
  console.log(`cell  ${toCell(d)} isCell=${isCell(d)}`);
  return 0;
}
