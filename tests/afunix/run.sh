#!/bin/sh
# run.sh [RUNTIME]: check AF_UNIX sockets between a Windows program under the runtime and the host.
#
#   client  the Windows program connects to a socket the host listens on (what xgameruntime
#           does to reach the Xodus service)
#   server  the Windows program binds and listens, the host connects; then Windows deletes
#           the socket file
#
# RUNTIME defaults to the build in $ENGINE_WORK/dist. The probe is built with llvm-mingw into
# $ENGINE_WORK/probes; the Wine prefix is $ENGINE_WORK/prefix-probe (created when missing).
# Sockets live in /tmp (short paths: sun_path holds 104 bytes on macOS). Exit 0 when both pass.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
PREFIX="$WORK/prefix-probe"
PROBE="$WORK/probes/afunix-probe.exe"
require_runtime
build_probe afunix-probe -lws2_32
ensure_prefix

# windows_path PATH: the Z: drive path Wine maps to a host path, with backslashes as
# xgameruntime writes it.
windows_path() { printf 'Z:%s' "$1" | tr / '\\'; }

name="macrock-afunix-$$"
host=
cleanup() {
  [ -z "$host" ] || kill "$host" 2>/dev/null || true
  rm -f "/tmp/$name-c.sock" "/tmp/$name-s.sock"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failed=0

# client: the host listens, Windows connects.
sock="/tmp/$name-c.sock"
rm -f "$sock"
$PYTHON - "$sock" <<'EOF' &
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
s.settimeout(120)
c, _ = s.accept()
data = c.recv(4, socket.MSG_WAITALL)
c.sendall(b"pong" if data == b"ping" else b"bad!")
c.close()
EOF
host=$!
wait_for 100 test -S "$sock" || die "host listener did not start"
result=$(run_wine "$PROBE" client "$(windows_path "$sock")" 2>/dev/null | tr -d '\r' | grep -E '^(OK|FAIL)' || true)
kill "$host" 2>/dev/null || true  # still waiting when the probe never connected
wait "$host" 2>/dev/null || true
host=
rm -f "$sock"
printf 'client: %s\n' "${result:-no result}"
[ "$result" = "OK client" ] || failed=1

# server: Windows listens, the host connects.
sock="/tmp/$name-s.sock"
log="$WORK/probes/afunix-server.log"
rm -f "$sock"
run_wine "$PROBE" server "$(windows_path "$sock")" > "$log" 2>&1 &
probe=$!
listening_or_gone() { [ -S "$sock" ] || ! kill -0 "$probe" 2>/dev/null; }
if wait_for 600 listening_or_gone && [ -S "$sock" ]; then
  reply=$($PYTHON - "$sock" <<'EOF' || true
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(sys.argv[1])
s.sendall(b"ping")
print(s.recv(4, socket.MSG_WAITALL).decode(errors="replace"))
EOF
)
  printf 'host got: %s\n' "${reply:-nothing}"
fi
wait "$probe" 2>/dev/null || true
result=$(tr -d '\r' < "$log" | grep -E '^(OK|FAIL)' || true)
printf 'server: %s\n' "${result:-no result}"
if [ "$result" != "OK server" ] || [ -e "$sock" ]; then
  [ -e "$sock" ] && printf 'server: socket file was not deleted\n'
  failed=1
fi
rm -f "$sock"

wineserver -k 2>/dev/null || true
[ "$failed" = 0 ] || die "AF_UNIX probe failed"
info "AF_UNIX probe: client and server passed"
