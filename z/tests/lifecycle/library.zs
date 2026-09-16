// The engine library as the lifecycle test links it: every production
// export (the engine module is imported whole) plus one test-only entry,
// a gated evaluation the test can pause after admission. Built as a
// separate artifact so the shipped library never carries the gate.
import { OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { Engine, initializeRuntime, retain, sliceToBytes } from "../../engine/lib.zs";
import { sliceBytes } from "../../engine/heap.zs";
import testing from "../../engine/native/zjs_testing.h";

export function initializeTestRuntime(): OnceLifetime<Engine> on thread.main {
  return initializeRuntime();
}

// The same evaluation as zjs_z_eval, pausing at `gate` (a zjs_gate the
// test owns, as a scalar) after admission and after taking the context
// lock, and reporting the evaluation's own error flag through the
// reference it holds -- the handle may be stale by then.
export c function zjs_z_eval_gated(handle: usize, source: Slice<u8>, gate: usize): i32 {
  const bytes = sliceToBytes(source);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): i32 => {
        testing.zjs_gate_arrive(gate);
        const byteCount = bytes.length;
        state.evaluate(sliceBytes(in bytes, 0, byteCount));
        return state.hadError ? 1 : 0;
      });
    }
    none => {
      return -1;
    }
  }
}
