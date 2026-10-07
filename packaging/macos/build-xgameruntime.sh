#!/bin/sh
# build-xgameruntime.sh [IMPORT OPTIONS]: build xodus-gaming/xgameruntime and install its DLL.
#
# `tools/engine import xgameruntime` generates the tree (options are passed to it), then CMake
# cross-compiles it with llvm-mingw, using Wine's own widl from build.sh's native tools stage
# (the project requires Wine's widl). Output: $DIST/lib/macrock-engine/x86_64-windows/
# xgameruntime.dll, a PE DLL that a prefix loads from C:\windows\system32 as Gaming Services
# would install it; the unit tests are built too ($WORK/build-xgameruntime/bin/test_xgameruntime.exe).
#
# Environment: JOBS (default 4), ENGINE_WORK, LLVM_MINGW, RECONFIGURE. Run build.sh first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

WIDL="$TOOLS/tools/widl/widl"
export LLVM_MINGW

[ -x "$MINGW_CC" ] || die "llvm-mingw not found; run bootstrap.sh"
[ -x "$WIDL" ] || die "Wine's widl not found in $TOOLS; run build.sh first"
[ -x "$DIST/bin/wine" ] || die "no runtime in $DIST; run build.sh first"
command -v cmake >/dev/null 2>&1 || die "cmake not found; run bootstrap.sh"

"$ENGINE" import xgameruntime "$@"

mkdir -p "$XGR_BUILD"
# The IDLs import Wine's (unknwn.idl...), which an installed widl finds in its own include
# directory; this widl is not installed, so point it at the Wine tree's headers.
cat > "$XGR_BUILD/widl" <<EOF
#!/bin/sh
exec "$WIDL" -I "$SRC/include" "\$@"
EOF
chmod +x "$XGR_BUILD/widl"
# The tests' CMake setup looks for wine on PATH to run them; use this runtime's.
export PATH="$DIST/bin:$PATH"
if [ ! -f "$XGR_BUILD/CMakeCache.txt" ] || [ -n "${RECONFIGURE:-}" ]; then
  info "Configuring xgameruntime"
  # C23: the C sources use thread_local, a keyword only since C23 (GCC 15's default; clang's
  # default is still C17). Windows 10 API level, as the GDK requires (mingw-w64 hides e.g.
  # IBufferByteAccess below Windows 8).
  win10="-D_WIN32_WINNT=0x0A00 -DNTDDI_VERSION=0x0A000000"
  run_logged "$XGR_BUILD/configure.log" cmake -S "$XGR_SRC" -B "$XGR_BUILD" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/llvm-mingw.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_STANDARD=23 -DCMAKE_C_FLAGS="$win10" -DCMAKE_CXX_FLAGS="$win10" \
    -DWIDL="$XGR_BUILD/widl" -DENABLE_TESTS=ON
fi
info "Building xgameruntime (log: $XGR_BUILD/build.log)"
run_logged "$XGR_BUILD/build.log" cmake --build "$XGR_BUILD" -j "$JOBS" --target xgameruntime test_xgameruntime

out="$DIST/lib/macrock-engine/x86_64-windows"
mkdir -p "$out"
cp "$XGR_BUILD/bin/xgameruntime.dll" "$out/"
info "xgameruntime -> $out/xgameruntime.dll"
