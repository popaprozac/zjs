// A borrowed view of one field held across a loop that mutates another
// field of the same owner.
//
// Found in the ZJS interpreter loop. The instruction stream is a field
// of the runtime and so is the register file; the loop reads one and
// writes the other. Z rejects holding an `in` view of the code array
// while the register file is written through `this`, so every
// instruction re-derives the code pointer from the owner (two indexings
// and their checks). In C this is one local pointer per frame. The
// engine works around it by keeping all code in one array and indexing
// by offset; the view itself is the ask.
//
// `view this.code` is the existing spelling for a borrowed view of a
// field. Both compilers reject the write to `this.registers[0]` while
// the view lives: sibling-field tracking is conservative at indexed
// access. The ask is that precision, with the existing syntax.
import console from "std/console";

struct Machine {
  code: Array<i32>;
  registers: Array<i32>;

  function run(inout this): i32 {
    const program = view this.code;
    let ip: usize = 0;
    while (ip < program.length) {
      const instruction = program[ip];
      this.registers[0] = this.registers[0] + instruction;
      ip = ip + 1;
    }
    return this.registers[0];
  }
}

function main(): i32 {
  let machine = Machine({ code: Array<i32>(), registers: Array<i32>() });
  machine.code.push(2);
  machine.code.push(3);
  machine.registers.push(0);
  if (machine.run() != 5) return 1;
  console.log("ok");
  return 0;
}
