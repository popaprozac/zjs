// A loop over a match whose arms the C compiler can give each a function
// and a register allocation of its own. The engine's dispatch loop was one
// very large function; a change to one arm moved clang's register
// allocation for all the others, and splitting it into handlers chained by
// tail calls measured calls -9% and closures -8% in a copy of the C.
//
// Landed in z-lang e75c8b0d as `dispatch while`: Stage 0 lowers each arm
// to a handler (musttail, preserve_none) and keeps the ordinary loop under
// Z_DISPATCH_THREADED for other C compilers.
import console from "std/console";

enum Op {
  add,
  dec,
  jump,
  halt,
}

// What the loop carries is plain data; the code it reads stays behind `this`.
struct Machine {
  code: Array<Op>;

  function run(inout this): i32 {
    let ip: usize = 0;
    let total: i32 = 0;
    let count: i32 = 5;
    let result: i32 = -1;
    dispatch while (true) {
      const op = this.code[ip];
      ip = ip + 1;
      match (op) {
        add => {
          total = total + count;
          continue;
        }
        dec => {
          count = count - 1;
          continue;
        }
        jump => {
          if (count > 0) {
            ip = 0;
            continue;
          }
        }
        halt => {
          result = total;
          break;
        }
      }
    }
    return result;
  }
}

function main(): i32 {
  let machine = Machine({ code: Array<Op>() });
  machine.code.push(Op.add);
  machine.code.push(Op.dec);
  machine.code.push(Op.jump);
  machine.code.push(Op.halt);
  if (machine.run() != 15) return 1;
  console.log("ok");
  return 0;
}
