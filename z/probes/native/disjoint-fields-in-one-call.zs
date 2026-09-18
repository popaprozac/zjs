// A call may borrow one field of `this` mutably while reading another:
// the two fields are disjoint storage.
import console from "std/console";
struct Lists {
  next: Array<i32>;
  buckets: Array<i32>;
  function carry(inout this, bucket: usize): void {
    this.next.push(this.buckets[bucket]);
  }
}
function main(): i32 {
  let lists = Lists({ next: Array<i32>(), buckets: Array<i32>() });
  lists.buckets.push(5);
  lists.carry(0);
  if (lists.next.length != 1 || lists.next[0] != 5) return 1;
  console.log("ok");
  return 0;
}
