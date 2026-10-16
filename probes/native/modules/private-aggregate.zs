// A module-private struct behind an exported one's field.
struct Hidden {
  value: i32;
}
export struct Holder {
  items: Array<Hidden>;
  function add(inout this, value: i32): void {
    this.items.push(Hidden({ value: value }));
  }
  function total(): i32 {
    let sum: i32 = 0;
    let i: usize = 0;
    while (i < this.items.length) {
      sum = sum + this.items[i].value;
      i = i + 1;
    }
    return sum;
  }
}
export function createHolder(): Holder {
  return Holder({ items: Array<Hidden>() });
}
