// A value read of `this` inside a call that borrows `this` mutably is rejected.
//
// Found writing the ZJS interpreter: every register write of the form
//   this.setReg(a, this.reg(b))
// fails with "overlapping inout and value uses of this in one call", so each
// operand is bound to a local first. Both `reg` and the read of a field are
// non-mutating; the sequencing is unambiguous (arguments evaluate before the
// call). This is the receiver-side twin of the in-borrow-with-field-read
// probe. If the rule is intentional, the diagnostic should name the
// bind-first workaround.
import console from "std/console";

struct Machine {
  regs: Array<i32>;

  function reg(index: usize): i32 {
    return this.regs[index];
  }

  function setReg(inout this, index: usize, value: i32): void {
    this.regs[index] = value;
  }

  function copy(inout this, dst: usize, src: usize): void {
    this.setReg(dst, this.reg(src));
  }
}

function main(): i32 {
  let machine = Machine({ regs: Array<i32>() });
  machine.regs.push(7);
  machine.regs.push(0);
  machine.copy(1, 0);
  if (machine.reg(1) != 7) return 1;
  console.log("ok");
  return 0;
}
