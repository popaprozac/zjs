# Sourced by the scripts that invoke the Z compiler. By default that is
# Stage 0 (`bun run z`) in the checkout $Z_LANG names; Z_BIN names a native
# compiler binary to use instead, so the same scripts build the engine with
# either. Every command form the scripts use (build, test, check, run) is
# accepted by both drivers.
Z_LANG="${Z_LANG:-$HOME/code/z-lang}"

zc() {
  if [ -n "${Z_BIN:-}" ]; then
    "$Z_BIN" "$@"
  else
    (cd "$Z_LANG" && bun run z "$@")
  fi
}

zc_describe() {
  if [ -n "${Z_BIN:-}" ]; then
    echo "native $Z_BIN"
  else
    echo "Stage 0 in $Z_LANG"
  fi
}
