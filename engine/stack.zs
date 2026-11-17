// The native stack's address, for the code that recurses on it: the
// runtime's limit (Runtime.stackShort) and the front end's, which runs
// without a runtime.

// About where the caller's frame is: clang puts this in the caller, as one
// register read. Stacks grow down, so a lower address is a deeper call.
export function stackAddress(): usize = raw c {
  return (uintptr_t)__builtin_frame_address(0);
}
