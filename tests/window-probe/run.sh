#!/bin/sh
# run.sh GPTK_LIB [RUNTIME]: check that a D3DMetal swapchain fills its window when windowed,
# after a resize and in borderless fullscreen (see d3d12-window-probe.c).
#
# GPTK_LIB is the lib directory of an imported Game Porting Toolkit (with external/ and wine/);
# RUNTIME defaults to the build in $ENGINE_WORK/dist. The probe (llvm-mingw) and the checker
# (swiftc) are built into $ENGINE_WORK/probes, captures are kept there; the Wine prefix is
# $ENGINE_WORK/prefix-probe, created when missing. The window is on screen for about 12 s; the
# terminal needs Screen Recording permission. Exit 0 when all three phases filled the window.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

GPTK=${1:?usage: run.sh GPTK_LIB [RUNTIME]}
RUNTIME=${2:-$DIST}
OUT="$WORK/probes"
PREFIX="$WORK/prefix-probe"
[ -f "$GPTK/external/libd3dshared.dylib" ] || die "no D3DMetal in $GPTK"
require_runtime
build_probe d3d12-window-probe -luser32
swiftc -O -o "$OUT/check-window" "$TESTS/check-window.swift"
ensure_prefix

results="$OUT/window-probe.results"
: > "$results"
cr=$(printf '\r')
info "Running the window probe on $RUNTIME"
# Read the probe's lines as they come (no buffering filter in between): each check must run
# while its phase is still on screen.
d3dmetal_env "$GPTK" "$RUNTIME/bin/wine" "$OUT/d3d12-window-probe.exe" 2>&1 | while IFS= read -r line; do
  line=${line%"$cr"}
  case $line in
    "PHASE "*)
      # shellcheck disable=SC2086
      set -- $line
      printf '%s (%s): ' "$2" "$4" | tee -a "$results"
      "$OUT/check-window" "D3D12 window probe" "$3" "$OUT/window-probe-$2.png" 2>&1 | tee -a "$results"
      ;;
    "FAIL "* | DONE) printf '%s\n' "$line" | tee -a "$results" ;;
  esac
done
wineserver -k 2>/dev/null || true

passed=$(grep -c '): ok ' "$results" || true)
if ! grep -q '^DONE$' "$results" || [ "$passed" != 3 ]; then
  die "window probe failed: $passed/3 phases (see $results and $OUT/window-probe-*.png)"
fi
info "window probe: 3/3 phases filled the window"
