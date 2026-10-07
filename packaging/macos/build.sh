#!/bin/sh
# build.sh [IMPORT OPTIONS]: build the x86_64 runtime into $WORK/dist/macrock-engine-<version>.
#
# First `tools/engine import wine` generates the Wine tree from the pinned commit and the series
# (options such as --with/--without/--from are passed to it; an unchanged series leaves the tree
# alone, so rebuilds stay incremental). Then two stages:
#   1. native arm64 Wine tools (makedep, winebuild, widl, wrc...), so the build does not run
#      thousands of x86_64 tool processes through Rosetta;
#   2. the x86_64 runtime: unix side with Apple clang, PE side with llvm-mingw;
# then build-xgameruntime.sh adds the GDK runtime (xodus-gaming/xgameruntime) and build-xodus.sh
# the Xodus service (native arm64).
# The result is relocatable (Wine resolves its directories relative to ntdll.so), so it can be
# packaged and moved.
#
# Environment: JOBS (default 4; 8 GB Macs should stay at 4-6), RECONFIGURE, REBUILD_TOOLS,
# ENGINE_WORK, LLVM_MINGW, GCENX_ARCHIVE. Run bootstrap.sh first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

DEPS="$WORK/deps-x86_64"
export LC_ALL=en_US.UTF-8
export MACOSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET
SDKROOT=$(xcrun --sdk "macosx$MACOS_SDK" --show-sdk-path 2>/dev/null) ||
  die "macOS $MACOS_SDK SDK not found; install the matching Command Line Tools"
export SDKROOT
export PATH="$LLVM_MINGW/bin:$(brew_prefix bison)/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Paths under WORK are hashed relative to it, so the cache survives moving the work directory.
export CCACHE_DIR="$WORK/ccache" CCACHE_MAXSIZE=10G CCACHE_COMPILERCHECK=content CCACHE_BASEDIR="$WORK"

[ -x "$MINGW_CC" ] || die "llvm-mingw not found; run bootstrap.sh"
[ -f "$GCENX_ARCHIVE" ] || die "Gcenx archive not found; run bootstrap.sh"
if [ -f "$DIST/lib/wine/x86_64-unix/ntdll.so" ] &&
   lsof -t "$DIST/lib/wine/x86_64-unix/ntdll.so" >/dev/null 2>&1; then
  die "close Wine applications using $DIST before rebuilding"
fi

"$ENGINE" import wine "$@"

CLANG=$(xcrun --find clang)
CLANGXX=$(xcrun --find clang++)
CCACHE=
command -v ccache >/dev/null 2>&1 && CCACHE=ccache

# --- Stage 1: native arm64 tools ------------------------------------------------------------
if [ ! -x "$TOOLS/tools/winebuild/winebuild" ] || [ -n "${REBUILD_TOOLS:-}" ]; then
  info "Building native arm64 tools"
  mkdir -p "$TOOLS"
  (
    cd "$TOOLS"
    export CC="$CCACHE $CLANG -arch arm64" CXX="$CCACHE $CLANGXX -arch arm64"
    run_logged "$TOOLS/configure.log" "$SRC/configure" \
      --enable-archs=aarch64 --with-mingw=llvm-mingw --disable-tests \
      --without-x --without-gnutls --without-vulkan --without-gstreamer --without-ffmpeg \
      --without-unwind --without-sdl --without-cups --without-sane --without-krb5
    run_logged "$TOOLS/build.log" make -j"$JOBS" __tooldeps__
  )
fi
# wrc loads <tools>/nls/locale.nls, which a __tooldeps__-only build does not produce.
mkdir -p "$TOOLS/nls"
ln -sf "$SRC/nls/locale.nls" "$TOOLS/nls/locale.nls"

# --- x86_64 GnuTLS/FreeType dylibs ----------------------------------------------------------
if [ ! -f "$DEPS/lib/libgnutls.30.dylib" ]; then
  info "Extracting x86_64 GnuTLS/FreeType"
  rm -rf "$DEPS"
  $PYTHON "$HERE/extract-deps.py" "$GCENX_ARCHIVE" "$DEPS/lib"
  install_name_tool -id '@rpath/libfreetype.6.dylib' "$DEPS/lib/libfreetype.6.dylib"
  run_logged "$WORK/deps-codesign.log" codesign --force --sign - "$DEPS/lib/libfreetype.6.dylib"
fi

# --- Stage 2: x86_64 runtime ----------------------------------------------------------------
mkdir -p "$BUILD"
cd "$BUILD"
export CC="$CCACHE $CLANG -arch x86_64" CXX="$CCACHE $CLANGXX -arch x86_64"
export OBJC="$CCACHE $CLANG -arch x86_64"
export CFLAGS=-O2 CXXFLAGS=-O2 OBJCFLAGS=-O2 CROSSCFLAGS=-O2
export x86_64_CC="$CCACHE x86_64-w64-mingw32-clang" x86_64_CXX="$CCACHE x86_64-w64-mingw32-clang++"
# Homebrew provides architecture-independent headers; the libraries are the x86_64 dylibs
# above, which Wine dlopens by the sonames below (relative to lib/wine/x86_64-unix).
export GNUTLS_CFLAGS="-I$(brew_prefix gnutls)/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls"
export FREETYPE_CFLAGS="-I$(brew_prefix freetype)/include/freetype2"
export FREETYPE_LIBS="-L$DEPS/lib -Wl,-rpath,$DEPS/lib -lfreetype"
export ac_cv_lib_soname_gnutls='@loader_path/../../libgnutls.30.dylib'
export ac_cv_lib_soname_freetype='@loader_path/../../libfreetype.6.dylib'
if [ ! -f Makefile ] || [ "$SRC/configure" -nt Makefile ] || [ -n "${RECONFIGURE:-}" ] ||
   [ "$(cat .engine-prefix 2>/dev/null)" != "$DIST" ]; then
  info "Configuring x86_64 runtime"
  run_logged "$BUILD/configure.log" "$SRC/configure" \
    --build=aarch64-apple-darwin --host=x86_64-apple-darwin \
    --prefix="$DIST" --with-wine-tools="$TOOLS" \
    --enable-archs=x86_64 --with-mingw=llvm-mingw --disable-tests \
    --without-x --with-freetype --with-gnutls --without-vulkan \
    --without-gstreamer --without-ffmpeg --without-sdl --without-cups --without-sane --without-krb5
  printf '%s\n' "$DIST" > .engine-prefix
fi

info "Building with -j$JOBS (log: $BUILD/build.log)"
start=$(date +%s)
run_logged "$BUILD/build.log" make -j"$JOBS"

# Install into a clean tree so no file from an older build is packaged.
rm -rf "$DIST"
run_logged "$BUILD/install.log" make install
cp -a "$DEPS/lib/." "$DIST/lib/"
# bin/wine is normally tools/wine/wine, an in-process launcher that must match ntdll's
# architecture; with arm64 tools it is not installed. The x86_64 loader works directly.
ln -sf ../lib/wine/x86_64-unix/wine "$DIST/bin/wine"
info "Built in $(( ($(date +%s) - start) / 60 )) min -> $DIST"
"$DIST/bin/wine" --version

# What a Wine prefix needs from this runtime, for the launcher (tests/game/prefix-setup.py
# applies it the same way).
mkdir -p "$DIST/share/macrock-engine/prefix"
cp "$HERE/prefix/setup.json" "$HERE/prefix/"*.reg "$DIST/share/macrock-engine/prefix/"

# The GDK runtime: a PE DLL built with this Wine's widl, installed into the fresh $DIST; and the
# Xodus service it talks to.
"$HERE/build-xgameruntime.sh"
"$HERE/build-xodus.sh"
