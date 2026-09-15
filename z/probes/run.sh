#!/usr/bin/env bash
# Executable acceptance criteria for docs/z-findings.md.
#
# Each probe is a small Z program that compiles and runs only when its finding
# has landed. This is the contract between ZJS and z-lang: Codex can develop
# against these without reading the engine, and ZJS learns automatically when
# a finding is ready to adopt.
#
#   LANDED  — the feature works; ZJS can drop its workaround
#   PENDING — not yet available (expected for open findings)
set -uo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"

pinned="$(cd "$Z_LANG" && git rev-parse --short HEAD)"
echo "z-lang @ $pinned"
echo

landed=0; pending=0
for probe in "$HERE"/g*.zs; do
  name="$(basename "$probe" .zs)"
  if (cd "$Z_LANG" && bun run z run "$probe" >/dev/null 2>&1); then
    printf "  %-34s LANDED\n" "$name"; landed=$((landed+1))
  else
    printf "  %-34s pending\n" "$name"; pending=$((pending+1))
  fi
done

echo
echo "$landed landed, $pending pending"
echo "detail: cd $Z_LANG && bun run z run $HERE/<probe>.zs"
