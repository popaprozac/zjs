# Windows build driver -- the Makefile is POSIX-only (Darwin/Linux
# branches, symlinks, uname), so Windows builds go through this script.
#
# Shared prep (both modes):
#   1. `std` junction -> Zen-c stdlib (zc resolves std/ against cwd --
#      same workaround as the Makefile's `ln -sfn`, junction-flavored).
#   2. Embed src/stdlib/*.js as .gen.h headers (tools/embed_js.py).
#
# Modes:
#   (default)   `zc build` the CLI -> build/zjs.exe (the //> windows:
#               directives in tools/zjs.zc supply platform sources + libs).
#   -Lib        Static archive build/libzjs.a for embedding (the C ABI in
#               include/zjs.h), then link + run tests/embed_smoke.c (the
#               399-assert ABI gate) against it. Mirrors `make lib-static`
#               + `make smoke-static`.
#
# Usage:
#   powershell -File scripts\build-windows.ps1               # release CLI
#   powershell -File scripts\build-windows.ps1 -DebugBuild   # CLI, -O0 -g
#   powershell -File scripts\build-windows.ps1 -Lib          # libzjs.a + ABI gate
#
# Prereqs: zc on PATH (ZC_ROOT auto-derived from its location if unset),
# MinGW-w64 gcc + ar on PATH, python3.

param(
    [switch]$DebugBuild,
    [switch]$Lib
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# Per-platform artifact dir: build/<os>-<arch>/ (matches the layout the
# runners resolve and the Makefile's BUILD_DIR convention). x64 is the
# only Windows arch we build today.
$OutDir = "build\win-x64"
$ObjDir = "$OutDir\obj"

# Win32 link libraries (kept in sync with the //> windows: link
# directives in src/lib.zc + tools/zjs.zc): bcrypt = CSPRNG +
# crypto.subtle, psapi = peak RSS, winhttp = fetch/WS, ws2_32 =
# node:net, z = node:zlib.
$WinLibs = @("-lbcrypt", "-lpsapi", "-lwinhttp", "-lws2_32", "-lz")
# Warning silencers for the zc-transpiled C (same set zc passes).
$Warns = @(
    "-Wno-parentheses", "-Wno-unused-value", "-Wno-unused-variable",
    "-Wno-unused-parameter", "-Wno-unused-function",
    "-Wno-unused-but-set-variable", "-Wno-sign-compare",
    "-Wno-missing-field-initializers", "-Wno-incompatible-pointer-types")
$DeadStrip = @("-ffunction-sections", "-fdata-sections")

# --- Shared step 1: ZC_ROOT + std junction ----------------------------
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

# --- Shared step 2: embed stdlib JS -----------------------------------
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

New-Item -ItemType Directory -Force $OutDir | Out-Null

if (-not $Lib) {
    # === CLI mode ====================================================
    $flags = if ($DebugBuild) { @("-w", "-O0", "-g", "-Isrc") }
             else             { @("-w", "--release", "-Isrc") }
    Write-Host "zc build $($flags -join ' ') tools/zjs.zc -o $OutDir\zjs.exe"
    zc build @flags tools/zjs.zc -o "$OutDir/zjs.exe"
    if ($LASTEXITCODE -ne 0) { Write-Error "zc build failed" }
    Write-Host "OK: $OutDir\zjs.exe"
    return
}

# === lib-static mode =================================================
# zc's `--release -c`/`-shared` analyzers reject some patterns the CLI
# build accepts, so (like the Makefile) we transpile to one C TU and
# drive gcc + ar ourselves.
New-Item -ItemType Directory -Force $ObjDir | Out-Null
$qjs = @("-Isrc/third-party/qjs-regex", "-DCONFIG_ALL_UNICODE")
$libC = "$OutDir\libzjs.c"
$libA = "$OutDir\libzjs.a"

Write-Host "[lib] transpile engine -> $libC"
zc transpile -w --release -Isrc src/lib.zc -o $libC
if ($LASTEXITCODE -ne 0) { Write-Error "zc transpile failed" }

# Each compile: gcc -O3 <deadstrip> <warns> [extra] -c <src> -o <obj>
$units = @(
    @{ src = $libC;                                     obj = "$ObjDir\libzjs.o";          extra = (@("-Isrc") + $qjs) },
    @{ src = "src/platform/http_windows.c";             obj = "$ObjDir\http_windows.o";    extra = @("-Isrc") },
    @{ src = "src/platform/ws_windows.c";               obj = "$ObjDir\ws_windows.o";      extra = @("-Isrc") },
    @{ src = "src/platform/socket_windows.c";           obj = "$ObjDir\socket_windows.o";  extra = @("-Isrc") },
    @{ src = "src/platform/process_windows.c";          obj = "$ObjDir\process_windows.o"; extra = @("-Isrc") },
    @{ src = "src/platform/qjs_regex_shim.c";           obj = "$ObjDir\qjs_regex_shim.o";  extra = $qjs },
    @{ src = "src/third-party/qjs-regex/libregexp.c";   obj = "$ObjDir\qjs_libregexp.o";   extra = $qjs },
    @{ src = "src/third-party/qjs-regex/libunicode.c";  obj = "$ObjDir\qjs_libunicode.o";  extra = $qjs },
    @{ src = "src/third-party/aes-gcm/aes_gcm.c";       obj = "$ObjDir\aes_gcm.o";         extra = @() }
)
foreach ($u in $units) {
    Write-Host "[lib] cc $($u.src)"
    & gcc -O3 @DeadStrip @Warns @($u.extra) -c $u.src -o $u.obj
    if ($LASTEXITCODE -ne 0) { Write-Error "compile failed: $($u.src)" }
}

Write-Host "[lib] ar -> $libA"
if (Test-Path $libA) { Remove-Item $libA }
& ar rcs $libA (Get-ChildItem "$ObjDir\*.o" | ForEach-Object { $_.FullName })
if ($LASTEXITCODE -ne 0) { Write-Error "ar failed" }
$sz = (Get-Item $libA).Length / 1MB
Write-Host ("OK: $libA ({0:N2} MB)" -f $sz)

# ABI gate: link tests/embed_smoke.c against the archive and run it.
# -static pulls libwinpthread/libgcc in so the .exe has no MinGW DLL
# runtime dependency (http_windows.c's async path uses pthreads).
Write-Host "[lib] building + running embed_smoke (ABI gate) ..."
& gcc -O0 -g -Wall -static -Iinclude tests/embed_smoke.c $libA -lm @WinLibs -o "$OutDir/smoke_static.exe"
if ($LASTEXITCODE -ne 0) { Write-Error "smoke link failed" }
& "$OutDir/smoke_static.exe"
if ($LASTEXITCODE -ne 0) { Write-Error "embed_smoke FAILED (ABI gate)" }
Write-Host "OK: $libA passes the embed_smoke ABI gate"
