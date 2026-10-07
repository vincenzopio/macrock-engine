#!/bin/sh
# package.sh [--dev]: turn $WORK/dist/macrock-engine-<version> into the release a launcher
# downloads, in $WORK/packages:
#
#   macrock-engine-<version>.bundle      the runtime as a macOS bundle (also kept unpacked):
#     Contents/Info.plist                dev.macrock.engine, the version and build number
#     Contents/Resources/manifest.json   what it was built from, what it requires, and the
#                                        SHA-256 of every file of runtime/
#     Contents/Resources/runtime/        Wine, xgameruntime.dll, the prefix setup, licenses
#     Contents/_CodeSignature/           an ad hoc seal over all of it (codesign --verify)
#   macrock-engine-<version>.aar         the bundle in an Apple Archive (lzma)
#   xodus-service-<version>-arm64.aar    the Xodus service with its licenses, for the launcher's
#                                        app bundle (where the launcher signs it), not the runtime
#   index.json                           size and SHA-256 of both archives, and the requirements
#
# Development files (headers, import libraries, man pages, unversioned dylib links) stay out.
# Every bundled dylib needs its license texts (licenses/dylibs.txt). Uncommitted work, or a tree
# that does not match its series, is refused unless --dev. Run build.sh first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

DEV=0
case ${1:-} in --dev) DEV=1 ;; esac

[ -x "$DIST/lib/wine/x86_64-unix/wine" ] || die "no build in $DIST; run build.sh"
[ -f "$DIST/lib/macrock-engine/x86_64-windows/xgameruntime.dll" ] || die "no xgameruntime in $DIST; run build.sh"
[ -x "$DIST/libexec/xodus-service" ] || die "no xodus-service in $DIST; run build.sh"
[ -f "$DIST/share/macrock-engine/prefix/setup.json" ] || die "no prefix setup in $DIST; run build.sh"

engine_commit=$(git -C "$ROOT" rev-parse HEAD)
build=$(git -C "$ROOT" rev-list --count HEAD)
problems=
[ -z "$(git -C "$ROOT" status --porcelain -- VERSION LICENSE.md sources.json components tools packaging)" ] ||
  problems="macrock-engine has uncommitted changes"
for component in wine xgameruntime xodus; do
  "$ENGINE" status "$component" | grep -q "matches the series" ||
    problems="${problems:+$problems; }the $component tree does not match its series (run build.sh)"
done
if [ -n "$problems" ]; then
  [ "$DEV" = 1 ] || die "$problems; or package with --dev"
  info "warning: $problems; the manifest records it"
fi

# patch_list TREE: the applied patches of a generated tree, one line each.
patch_list() {
  git -C "$1" log --reverse --format='- [%(trailers:key=Topic,valueonly,separator=)] %s (%an)' engine/base..HEAD
}

OUT="$WORK/packages"
NAME="macrock-engine-$VERSION"
BUNDLE="$OUT/$NAME.bundle"
RESOURCES="$BUNDLE/Contents/Resources"
RUNTIME="$RESOURCES/runtime"
mkdir -p "$OUT"
rm -rf "$BUNDLE" "$OUT/$NAME.aar" "$OUT/xodus-service-$VERSION" "$OUT/xodus-service-$VERSION-arm64.aar" \
  "$OUT/index.json"
mkdir -p "$RUNTIME"

info "Copying the runtime into $NAME.bundle"
tar -C "$DIST" --exclude ./include --exclude ./share/man --exclude ./libexec --exclude '*.a' \
  --exclude ./lib/libgnutls.dylib --exclude ./lib/libfreetype.dylib -cf - . | tar -C "$RUNTIME" -xpf -

# Licenses: Wine's and the components', the texts of every bundled dylib, and SOURCES.md.
doc="$RUNTIME/share/doc/macrock-engine"
mkdir -p "$doc/licenses"
cp "$SRC/COPYING.LIB" "$SRC/LICENSE" "$SRC/AUTHORS" "$doc/"
cp "$ROOT/LICENSE.md" "$doc/LICENSE-macrock-engine.md"
cp "$XGR_SRC/LICENSE" "$doc/LICENSE-xgameruntime"
cp "$XGR_SRC/external/libxml2/Copyright" "$doc/LICENSE-libxml2"
cp -R "$HERE/licenses/llvm-mingw" "$doc/licenses/"
for dylib in "$RUNTIME"/lib/*.dylib; do
  name=$(basename "$dylib")
  project=$(awk -v name="$name" '!/^#/ && index(name, $1) == 1 { print $2; exit }' "$HERE/licenses/dylibs.txt")
  [ -n "$project" ] && [ -d "$HERE/licenses/$project" ] || die "no license texts for lib/$name (licenses/dylibs.txt)"
  [ -d "$doc/licenses/$project" ] || cp -R "$HERE/licenses/$project" "$doc/licenses/"
done
{
  cat <<EOF
# macrock-engine $VERSION sources

The runtime is Wine at $(pin wine ref) (commit $(pin wine commit), $(pin wine url))
with the patches of macrock-engine (commit $engine_commit) applied in this order, licensed
LGPL-2.1-or-later (COPYING.LIB). Each patch names its author and origin.

EOF
  patch_list "$SRC"
  cat <<EOF

lib/macrock-engine/x86_64-windows/xgameruntime.dll is xodus-gaming/xgameruntime at
$(pin xgameruntime ref) (commit $(pin xgameruntime commit), $(pin xgameruntime url))
with these patches, licensed LGPL-2.1-or-later (LICENSE-xgameruntime). It is statically linked
with libxml2 (MIT, LICENSE-libxml2) and with the LLVM C++ and mingw-w64 runtimes of llvm-mingw
(licenses/llvm-mingw).

EOF
  patch_list "$XGR_SRC"
  cat <<EOF

lib/*.dylib (GnuTLS, FreeType and their dependencies) are unmodified x86_64 builds taken
from $GCENX_URL
(SHA-256 $GCENX_SHA256); their licenses are in licenses/ (see dylibs.txt in macrock-engine's
packaging/macos/licenses for which library is which).

The corresponding source of everything above is the upstream commits named here plus the patch
files of macrock-engine at commit $engine_commit (https://github.com/$REPO).
EOF
} > "$doc/SOURCES.md"

$PYTHON - "$BUNDLE/Contents/Info.plist" "$VERSION" "$build" "$MACOS_DEPLOYMENT_TARGET" <<'EOF'
import plistlib, sys
path, version, build, target = sys.argv[1:]
with open(path, "wb") as f:
    plistlib.dump({
        "CFBundleIdentifier": "dev.macrock.engine",
        "CFBundleName": "macrock-engine",
        "CFBundlePackageType": "BNDL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundleDevelopmentRegion": "en",
        "LSMinimumSystemVersion": target,
    }, f)
EOF
$PYTHON "$HERE/manifest.py" write --runtime "$RUNTIME" --out "$RESOURCES/manifest.json" --version "$VERSION" \
  --build "$build" --target "$MACOS_DEPLOYMENT_TARGET" --engine-root "$ROOT" --work "$WORK" \
  --engine-commit "$engine_commit" ${problems:+--dirty} --component wine --component xgameruntime \
  --gptk "$GPTK_REQUIRED" > /dev/null

info "Sealing $NAME.bundle (ad hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"
info "Writing $NAME.aar"
aa archive -D "$BUNDLE" -o "$OUT/$NAME.aar.part" -a lzma
mv "$OUT/$NAME.aar.part" "$OUT/$NAME.aar"

# The Xodus service, for the launcher: its own archive with its licenses (GPL-3.0 and the Rust
# crates'). Signed ad hoc here; the launcher signs it with its own identity.
helper="$OUT/xodus-service-$VERSION"
mkdir -p "$helper"
cp "$DIST/libexec/xodus-service" "$helper/xodus-service"
codesign --force --sign - --timestamp=none --identifier dev.macrock.xodus-service "$helper/xodus-service"
cp "$XODUS_SRC/LICENSE" "$helper/LICENSE"
PATH="$(brew_prefix rustup)/bin:$PATH" $PYTHON "$HERE/crate-licenses.py" "$XODUS_SRC" xodus-service \
  "$RUST_TOOLCHAIN" "$HERE/licenses/common" "$helper/THIRD-PARTY-LICENSES.md"
{
  cat <<EOF
# xodus-service $VERSION sources

xodus-gaming/xodus at $(pin xodus ref) (commit $(pin xodus commit), $(pin xodus url)) with the
patches of macrock-engine (commit $engine_commit, https://github.com/$REPO,
components/xodus) applied in this order, licensed GPL-3.0-only (LICENSE). Its Rust dependencies
are those of the upstream Cargo.lock (THIRD-PARTY-LICENSES.md).

EOF
  patch_list "$XODUS_SRC"
} > "$helper/SOURCES.md"
aa archive -D "$helper" -o "$OUT/xodus-service-$VERSION-arm64.aar" -a lzma
rm -rf "$helper"

$PYTHON "$HERE/manifest.py" index "$RESOURCES/manifest.json" "$OUT/$NAME.aar" \
  "$OUT/xodus-service-$VERSION-arm64.aar" "$OUT/index.json"
for file in "$NAME.aar" "xodus-service-$VERSION-arm64.aar"; do
  (cd "$OUT" && shasum -a 256 "$file" > "$file.sha256")
  info "$(du -h "$OUT/$file" | cut -f 1) $file ($(cut -d ' ' -f 1 < "$OUT/$file.sha256"))"
done
info "Release files in $OUT: $NAME.aar, xodus-service-$VERSION-arm64.aar, index.json"
