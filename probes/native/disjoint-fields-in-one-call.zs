// A call may borrow one field of `this` mutably while an argument reads
// another: the two fields are separately owned storage. The engine's heap
// pushes one table's entry into another this way, its parser writes a
// position computed from one field into its AST, and its compiler pushes
// a record built from its counters into its tables. An argument that
// reads a scalar sibling field, or calls an immutable method of `this`,
// is already accepted; an indexed read of a sibling array is not.
//
// What must stay rejected is the compiler's to test: genuinely
// overlapping loans (the same field on both sides), a field and its
// owner, and storage that may alias through a shared reference.
import console from "std/console";
struct Lists {
  next: Array<i32>;
  buckets: Array<i32>;
  limit: i32;
  function carry(inout this, bucket: usize): void {
    this.next.push(this.buckets[bucket]);
  }
  function carryLimit(inout this): void {
    this.next.push(this.limit);
  }
}
function main(): i32 {
  let lists = Lists({ next: Array<i32>(), buckets: Array<i32>(), limit: 4 });
  lists.buckets.push(5);
  lists.carry(0);
  if (lists.next.length != 1 || lists.next[0] != 5) return 1;
  lists.carryLimit();
  if (lists.next.length != 2 || lists.next[1] != 4) return 2;
  console.log("ok");
  return 0;
}
