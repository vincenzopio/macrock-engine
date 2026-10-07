# Shared by the tests: packaging/macos/lib.sh, and running Windows programs under a runtime.
# Source after setting TESTS (the test's directory); set RUNTIME and PREFIX before calling the
# functions.
# shellcheck shell=sh

HERE="$TESTS/../../packaging/macos"
. "$HERE/lib.sh"

# wine_env [NAME=value...] COMMAND...: run a command in a clean environment for the runtime and
# the prefix, with any extra variables (later ones win).
wine_env() {
  env -i HOME="$HOME" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin LC_ALL=en_US.UTF-8 \
    WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC="${WINEMSYNC:-1}" \
    WINEDLLOVERRIDES="mscoree,mshtml=" "$@"
}

# d3dmetal_env GPTK_LIB [NAME=value...] COMMAND...: wine_env, with D3DMetal from an imported Game
# Porting Toolkit's lib directory replacing Wine's Direct3D.
d3dmetal_env() {
  _gptk=$1; shift
  wine_env WINEDLLOVERRIDES="mscoree,mshtml=;d3d12,d3d11,d3d10,dxgi=b;nvapi64=" \
    WINEDLLPATH_PREPEND="$_gptk/wine" CX_APPLEGPTK_LIBD3DSHARED_PATH="$_gptk/external/libd3dshared.dylib" \
    CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal D3DM_SUPPORT_DXR=0 D3DM_MTL4="${D3DM_MTL4:-1}" "$@"
}

# run_wine PROGRAM [ARGS...]: run a Windows program under the runtime.
run_wine() { wine_env "$RUNTIME/bin/wine" "$@"; }

wineserver() { WINEPREFIX="$PREFIX" "$RUNTIME/bin/wineserver" "$@"; }

require_runtime() { [ -x "$RUNTIME/bin/wine" ] || die "no runtime in $RUNTIME"; }

# ensure_prefix: create PREFIX when it does not exist.
ensure_prefix() {
  [ -d "$PREFIX" ] && return
  info "Creating $PREFIX"
  mkdir -p "$(dirname "$PREFIX")"
  run_logged "$PREFIX.log" run_wine wineboot -u
  wineserver -w
}

# build_probe NAME [LINKER ARGS...]: build $TESTS/NAME.c with llvm-mingw into $WORK/probes/NAME.exe.
build_probe() {
  [ -x "$MINGW_CC" ] || die "llvm-mingw not found (LLVM_MINGW)"
  _probe=$1; shift
  mkdir -p "$WORK/probes"
  "$MINGW_CC" -O2 -Wall -o "$WORK/probes/$_probe.exe" "$TESTS/$_probe.c" "$@"
}

# wait_for TENTHS COMMAND...: run a command until it succeeds, for up to TENTHS tenths of a second.
wait_for() {
  _tenths=$1; shift
  until "$@"; do
    [ "$_tenths" -gt 0 ] || return 1
    _tenths=$((_tenths - 1))
    sleep 0.1
  done
}
