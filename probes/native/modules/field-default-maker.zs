// The struct and its maker that probes/native/imported-call-in-field-default.zs
// names in a field default.
export struct Info {
  names: Array<u32>;
}

export function emptyInfo(): Info {
  return Info({ names: Array<u32>() });
}
