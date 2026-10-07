#!/bin/sh
# run.sh [RUNTIME]: run xgameruntime's own unit tests (googletest) under the runtime.
#
# The tests initialize the GDK runtime, which connects to the Xodus service socket through
# AF_UNIX. Unless XODUS_SOCKET names a running service, a stand-in listener that accepts and
# stays silent is started on a private socket, and the run also requires that the runtime
# connected to it (the whole IPC path: xgameruntime, Wine's AF_UNIX support, the host socket).
# The tests are built by packaging/macos/build-xgameruntime.sh; the Wine prefix is
# $ENGINE_WORK/prefix-probe. Exit 0 when every test passes.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
BIN="$XGR_BUILD/bin"
PREFIX="$WORK/prefix-probe"
SOCKET=${XODUS_SOCKET:-}
require_runtime
[ -f "$BIN/test_xgameruntime.exe" ] || die "no tests in $BIN; run build-xgameruntime.sh"
ensure_prefix

# GTEST_FILTER and GTEST_REPEAT reach the tests (googletest reads them), as does
# XGR_XODUS_NO_ACCOUNT (see tests/xodus/run.sh); WINEMSYNC=0 compares without msync.
run_tests() {
  wine_env GTEST_FILTER="${GTEST_FILTER:-*}" GTEST_REPEAT="${GTEST_REPEAT:-1}" XODUS_SOCKET="$SOCKET" \
    XGR_XODUS_NO_ACCOUNT="${XGR_XODUS_NO_ACCOUNT:-}" "$RUNTIME/bin/wine" test_xgameruntime.exe
}

connections="$XGR_BUILD/connections"
rm -f "$connections"
standin=
if [ -n "$SOCKET" ]; then
  [ -S "$SOCKET" ] || die "XODUS_SOCKET=$SOCKET: no service listening there"
else
  # A stand-in service that accepts connections, counts them and stays silent.
  standin=1
  SOCKET="${TMPDIR:-/tmp}/macrock-xgr-$$.sock"
  $PYTHON - "$SOCKET" "$connections" <<'EOF' &
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
os.chmod(sys.argv[1], 0o600)
s.listen(4)
held = []
while True:
    held.append(s.accept()[0])
    with open(sys.argv[2], "w") as f:
        f.write("%d\n" % len(held))
EOF
  listener=$!
  trap 'kill "$listener" 2>/dev/null || true; rm -f "$SOCKET"' EXIT
  trap 'exit 130' INT TERM
  wait_for 100 test -S "$SOCKET" || die "stand-in listener did not start"
fi

log="$XGR_BUILD/tests.log"
info "Running xgameruntime tests (log: $log)"
status=0
(cd "$BIN" && run_tests) > "$log" 2>&1 || status=$?
wineserver -k 2>/dev/null || true
tr -d '\r' < "$log" | grep -E '^\[(==========|  PASSED  |  FAILED  )\]' || true
[ "$status" = 0 ] || die "xgameruntime tests failed (exit $status; see $log)"
[ -n "$standin" ] || exit 0
count=$(cat "$connections" 2>/dev/null || echo 0)
info "Xodus stand-in: $count connection(s) from the runtime"
# The connection is made asynchronously: only a full run is long enough to require it.
[ -n "${GTEST_FILTER:-}" ] || [ "$count" -ge 1 ] || die "the runtime never connected to $SOCKET"
