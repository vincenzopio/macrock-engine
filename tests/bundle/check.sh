#!/bin/sh
# check.sh [PACKAGES] [--probe GPTK_LIB]: check a release as the launcher will receive it.
#
# PACKAGES (default $ENGINE_WORK/packages) holds index.json and the archives package.sh wrote.
# Each archive must have the size and SHA-256 the index gives. The bundle is extracted into a
# temporary directory and must pass codesign's strict verification and match its manifest file
# by file (no file missing, changed or extra); its Wine must start. The Xodus service archive
# must hold an arm64 binary with a valid signature and its licenses. With --probe, the D3D12
# window probe (tests/window-probe) runs on the extracted runtime too. Exit 0 when all pass.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

PACKAGES="$WORK/packages"
PROBE=
while [ $# -gt 0 ]; do
  case $1 in
    --probe) PROBE=$2; shift 2 ;;
    *) PACKAGES=$1; shift ;;
  esac
done
INDEX="$PACKAGES/index.json"
[ -f "$INDEX" ] || die "no index.json in $PACKAGES (run package.sh)"

failed=0
# check NAME COMMAND...: run a check and report it.
check() {
  _name=$1; shift
  if "$@" > /dev/null 2>&1; then printf 'PASS %s\n' "$_name"; else printf 'FAIL %s\n' "$_name"; failed=1; fi
}
same() { [ "$1" = "$2" ]; }

for part in bundle helper; do
  file="$PACKAGES/$(json_get "$INDEX" "$part.file")"
  check "$part archive size" same "$(stat -f %z "$file")" "$(json_get "$INDEX" "$part.size")"
  check "$part archive SHA-256" same "$(sha256_of "$file")" "$(json_get "$INDEX" "$part.sha256")"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/macrock-bundle-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT TERM
aa extract -i "$PACKAGES/$(json_get "$INDEX" bundle.file)" -d "$T"
bundle="$T/$(json_get "$INDEX" bundle.path)"
runtime="$bundle/Contents/Resources/runtime"
check "bundle seal (codesign --verify --strict)" codesign --verify --strict "$bundle"
check "bundle files match the manifest" $PYTHON "$HERE/manifest.py" verify "$bundle/Contents/Resources"
check "manifest is clean" same "$(json_get "$bundle/Contents/Resources/manifest.json" dirty)" false
check "wine starts ($("$runtime/bin/wine" --version 2>/dev/null || echo no version))" "$runtime/bin/wine" --version
check "prefix setup present" test -f "$runtime/share/macrock-engine/prefix/setup.json"

aa extract -i "$PACKAGES/$(json_get "$INDEX" helper.file)" -d "$T"
helper="$T/$(json_get "$INDEX" helper.path)"
check "xodus-service is arm64" same "$(lipo -archs "$helper" 2>/dev/null)" arm64
check "xodus-service signature" codesign --verify --strict "$helper"
check "xodus-service licenses" test -s "$(dirname "$helper")/THIRD-PARTY-LICENSES.md" -a -s "$(dirname "$helper")/LICENSE"

if [ -n "$PROBE" ]; then
  check "D3D12 window probe on the extracted runtime" "$TESTS/../window-probe/run.sh" "$PROBE" "$runtime"
fi
exit "$failed"
