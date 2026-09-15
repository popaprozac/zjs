// G13c — a literal in `toEqual` against a u32 actual.  STATUS: proposed
//
// Confirmed at z-lang 00864194 (Stage 0). This is the case that escapes Z:
// `z check` accepts the file, then the generated C fails to compile with
// -Wsign-compare. Codex's diagnosis: generated storage is `uint32_t actual`
// versus `int32_t expected = 1U` -- contextual literal emission and the
// expectation's storage metadata disagree.
//
// This probe contains a test declaration, so the runner uses `z test`;
// `z run` excludes tests and cannot see this regression.
import { expect } from "std/test";

test "u32 actuals accept plain literals" {
  const handle: u32 = 1;
  expect(handle).toEqual(1);
}
