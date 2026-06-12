# Windows build driver -- the Makefile is POSIX-only (Darwin/Linux
# branches, symlinks, uname), so Windows builds go through this script
# instead. Mirrors the `make cli` recipe:
#
#   1. `std` junction -> Zen-c stdlib (zc resolves std/ against cwd --
#      same workaround as the Makefile's `ln -sfn`, junction-flavored).
#   2. Embed src/stdlib/*.js as .gen.h headers (tools/embed_js.py).
#   3. zc build the CLI (release flags; platform sources + link libs
#      come from the //> windows: directives in tools/zjs.zc).
#
# Usage:
#   powershell -File scripts\build-windows.ps1               # release CLI
#   powershell -File scripts\build-windows.ps1 -DebugBuild    # -O0 -g
#
# Prereqs: zc on PATH (ZC_ROOT auto-derived from its location if the
# env var isn't set), MinGW-w64 gcc on PATH, python3.

param(
    [switch]$DebugBuild
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# --- 1. Resolve ZC_ROOT + std junction --------------------------------
if (-not $env:ZC_ROOT) {
    $zc = Get-Command zc -ErrorAction SilentlyContinue
    if (-not $zc) { Write-Error "zc not found on PATH and ZC_ROOT not set" }
    $env:ZC_ROOT = Split-Path -Parent $zc.Source
}
if (-not (Test-Path (Join-Path $env:ZC_ROOT "std\third-party\tre\tre_full.c"))) {
    Write-Error "ZC_ROOT ($env:ZC_ROOT) doesn't contain std\ -- set ZC_ROOT to the Zen-c install dir"
}
if (-not (Test-Path "std")) {
    cmd /c mklink /J std "$env:ZC_ROOT\std" | Out-Null
    Write-Host "created std junction -> $env:ZC_ROOT\std"
}

# --- 2. Embed stdlib JS ------------------------------------------------
foreach ($js in Get-ChildItem src\stdlib\*.js) {
    $base = $js.BaseName
    $gen  = "src\stdlib\$base.gen.h"
    if ((Test-Path $gen) -and
        ((Get-Item $gen).LastWriteTime -gt $js.LastWriteTime)) { continue }
    $sym = $base.ToUpper() + "_SOURCE"
    python3 tools\embed_js.py $js.FullName $gen $sym
    if ($LASTEXITCODE -ne 0) { Write-Error "embed_js failed for $($js.Name)" }
    Write-Host "embedded $($js.Name) -> $gen"
}

# --- 3. Build ----------------------------------------------------------
New-Item -ItemType Directory -Force build | Out-Null
$flags = if ($DebugBuild) { @("-w", "-O0", "-g", "-Isrc") }
         else             { @("-w", "--release", "-Isrc") }
Write-Host "zc build $($flags -join ' ') tools/zjs.zc -o build/zjs.exe"
zc build @flags tools/zjs.zc -o build/zjs.exe
if ($LASTEXITCODE -ne 0) { Write-Error "zc build failed" }
Write-Host "OK: build\zjs.exe"
