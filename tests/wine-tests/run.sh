#!/bin/sh
# run.sh DLL [RUNTIME]: build Wine's conformance tests of DLL (dlls/DLL/tests) and run them
# under the runtime.
#
# build.sh configures Wine with --disable-tests, so the tests are built here with Wine's own
# compiler flags, headers and import libraries from the build tree ($ENGINE_WORK/build-x86_64),
# linked by winegcc. They run in a new prefix, $ENGINE_WORK/prefix-wine-tests, so that classes a
# patch registers are there. RUNTIME defaults to the build in $ENGINE_WORK/dist. Exit 0 when
# every test file passes.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

[ $# -ge 1 ] || die "usage: run.sh DLL [RUNTIME]"
DLL=$1
RUNTIME=${2:-$DIST}
DIR="$SRC/dlls/$DLL/tests"
OUT="$WORK/wine-tests/$DLL"
PREFIX="$WORK/prefix-wine-tests"
[ -f "$DIR/Makefile.in" ] || die "no tests in $DIR"
require_runtime
[ -f "$BUILD/Makefile" ] || die "no Wine build in $BUILD (run packaging/macos/build.sh)"
[ -x "$MINGW_CC" ] || die "llvm-mingw not found (LLVM_MINGW)"
export PATH="$LLVM_MINGW/bin:$PATH"

# makefile_list VAR: the words of a (possibly continued) VAR = ... line of the tests' Makefile.in.
makefile_list() {
  awk -v var="$1" '
    $0 ~ "^" var "[ \t]*=" { grab = 1; sub("^" var "[ \t]*=", "") }
    grab { more = sub(/\\$/, ""); print; if (!more) grab = 0 }
  ' "$DIR/Makefile.in" | tr -s ' \t' '\n\n' | grep -v '^$' || true
}

sources=$(makefile_list SOURCES)
for source in $sources; do
  case $source in *.c) ;; *) die "$DLL tests: $source is not supported, only C sources" ;; esac
done
names=$(for source in $sources; do sed -n 's/^START_TEST(\([A-Za-z0-9_]*\)).*/\1/p' "$DIR/$source"; done)
[ -n "$names" ] || die "$DLL tests: no START_TEST"

rm -rf "$OUT"
mkdir -p "$OUT"
{
  printf '#define WIN32_LEAN_AND_MEAN\n#include <windows.h>\n\n#define STANDALONE\n#include "wine/test.h"\n\n'
  for name in $names; do printf 'extern void func_%s(void);\n' "$name"; done
  printf '\nconst struct test winetest_testlist[] =\n{\n'
  for name in $names; do printf '    { "%s", func_%s },\n' "$name" "$name"; done
  printf '    { 0, 0 }\n};\n'
} > "$OUT/testlist.c"

flags="-I$DIR -I$BUILD/include -I$SRC/include -I$SRC/include/msvcrt -D_UCRT -D__WINESRC__ -D__WINE_PE_BUILD
  -Wall -fno-strict-aliasing -Wno-microsoft-enum-forward-reference -Wdeclaration-after-statement
  -Wstrict-prototypes -mlong-double-64 -mcx16 -O2 --no-default-config"
objects=
for source in $sources testlist.c; do
  [ "$source" = testlist.c ] && path="$OUT/testlist.c" || path="$DIR/$source"
  run_logged "$OUT/build.log" x86_64-w64-mingw32-clang -c -o "$OUT/${source%.c}.o" "$path" $flags
  objects="$objects $OUT/${source%.c}.o"
done
libs=
for import in $(makefile_list IMPORTS) ucrtbase kernel32 ntdll; do
  lib="$BUILD/dlls/$import/x86_64-windows/lib$import.a"
  [ -f "$lib" ] || die "$DLL tests: no import library for $import ($lib)"
  libs="$libs $lib"
done
info "Building the $DLL tests: $(echo $names)"
run_logged "$OUT/build.log" "$TOOLS/tools/winegcc/winegcc" -o "$OUT/${DLL}_test.exe" --wine-objdir "$BUILD" \
  --winebuild "$TOOLS/tools/winebuild/winebuild" --cc-cmd=x86_64-w64-mingw32-clang -b x86_64-w64-mingw32 \
  -mconsole $objects "$BUILD/libs/winecrt0/x86_64-windows/libwinecrt0.a" \
  "$BUILD/libs/compiler-rt/x86_64-windows/libcompiler-rt.a" $libs --no-default-config

rm -rf "$PREFIX"
ensure_prefix

failed=0
for name in $names; do
  log="$OUT/$name.log"
  status=0
  run_wine "$OUT/${DLL}_test.exe" "$name" > "$log" 2>&1 || status=$?
  summary=$(grep -a "tests executed" "$log" | tail -n 1 | sed 's/^[0-9a-f]*://')
  if [ "$status" -ne 0 ] || [ -z "$summary" ]; then
    grep -a "Test failed\|Test succeeded inside todo" "$log" | head -n 20 >&2 || true
    printf 'FAIL %s:%s (exit %s) %s\n' "$DLL" "$name" "$status" "$summary"
    failed=1
  else
    printf 'PASS %s:%s %s\n' "$DLL" "$name" "$summary"
  fi
done
wineserver -k 2> /dev/null || true
exit "$failed"
