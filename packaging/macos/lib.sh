# Shared helpers and paths for the macOS packaging scripts and the tests. Source after setting HERE.
# shellcheck shell=sh

ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$HERE/pins.sh"
VERSION=$(cat "$ROOT/VERSION")
ENGINE="$ROOT/tools/engine"
PYTHON="/usr/bin/python3 -I"

# Everything generated lives under WORK (Spotlight skips *.noindex). tools/engine reads the
# same variable, so the trees it generates are $WORK/src/<component>.
WORK=${ENGINE_WORK:-$ROOT/build.noindex}
export ENGINE_WORK="$WORK"
SRC="$WORK/src/wine"
XGR_SRC="$WORK/src/xgameruntime"
XODUS_SRC="$WORK/src/xodus"
DOWNLOADS="$WORK/downloads"
TOOLS="$WORK/tools-arm64"
BUILD="$WORK/build-x86_64"
XGR_BUILD="$WORK/build-xgameruntime"
XODUS_BUILD="$WORK/build-xodus"
DIST="$WORK/dist/macrock-engine-$VERSION"
JOBS=${JOBS:-4}
LLVM_MINGW=${LLVM_MINGW:-$WORK/toolchains/llvm-mingw-$LLVM_MINGW_VERSION}
MINGW_CC="$LLVM_MINGW/bin/x86_64-w64-mingw32-clang"
GCENX_ARCHIVE=${GCENX_ARCHIVE:-$DOWNLOADS/$(basename "$GCENX_URL")}

# build.sh exports Wine's x86_64 cross toolchain for its own stage; the other builds choose
# their compilers themselves.
unset CC CXX OBJC CFLAGS CXXFLAGS OBJCFLAGS CROSSCFLAGS LDFLAGS x86_64_CC x86_64_CXX

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

# json_get FILE KEY[.KEY...]: a value of a JSON file; strings as they are, the rest as JSON.
json_get() {
  $PYTHON -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value if isinstance(value, str) else json.dumps(value))' "$1" "$2"
}

# pin COMPONENT KEY: a value from sources.json.
pin() { json_get "$ROOT/sources.json" "components.$1.$2"; }

# fetch URL SHA256 DEST: download once into DEST, then verify its digest.
fetch() {
  if [ ! -f "$3" ]; then
    mkdir -p "$(dirname "$3")"
    info "Downloading $(basename "$3")"
    curl -fL --retry 3 -sS "$1" -o "$3.part"
    mv "$3.part" "$3"
  fi
  [ "$(sha256_of "$3")" = "$2" ] || die "SHA-256 mismatch for $3"
}

# brew_prefix FORMULA: where Homebrew links an installed formula.
brew_prefix() { printf '/opt/homebrew/opt/%s' "$1"; }

# run_logged LOG CMD...: run quietly; on failure show the end of the log.
run_logged() {
  _run_log=$1; shift
  if ! "$@" > "$_run_log" 2>&1; then
    tail -n 40 "$_run_log" >&2
    die "failed: $* (full log: $_run_log)"
  fi
}
