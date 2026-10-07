#!/bin/sh
# run.sh [RUNTIME]: check the Xodus service end to end.
#
#   1. start xodus-service (XODUS_SERVICE, default the build's libexec/xodus-service: release
#      bundles do not carry it) on a private socket (XODUS_SOCKET), with its
#      credentials in a test Keychain service (XODUS_KEYCHAIN_SERVICE, default
#      "macrock-engine test"), never a real account's; the first run registers a device with
#      Microsoft, as Xodus does, and needs the network;
#   2. speak its protocol from the host: a PING comes back as PONG with the same payload, a token
#      request without a signed-in user gets an empty answer, a game license request a failure
#      (the catalog lookup needs the network), and the connection still works;
#   3. run part of xgameruntime's tests under Wine against it, among them XUserAddAsync, which
#      must find no default user, and check from the service log that the runtime connected
#      (xgameruntime -> Wine AF_UNIX -> the real service).
# The service log is $ENGINE_WORK/build-xodus/test-service.log (service debug messages only; they
# carry no tokens). Exit 0 when everything passed.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
SERVICE=${XODUS_SERVICE:-$DIST/libexec/xodus-service}
SOCKET="${TMPDIR:-/tmp}/macrock-xodus-$$.sock"
LOG="$XODUS_BUILD/test-service.log"
[ -x "$SERVICE" ] || die "no xodus-service at $SERVICE; run build-xodus.sh"
mkdir -p "$(dirname "$LOG")"

info "Starting $SERVICE"
XODUS_SOCKET="$SOCKET" XODUS_KEYCHAIN_SERVICE="${XODUS_KEYCHAIN_SERVICE:-macrock-engine test}" \
  XODUS_LOG="xodus_service=debug" "$SERVICE" > "$LOG" 2>&1 &
service=$!
trap 'kill "$service" 2>/dev/null || true; wait "$service" 2>/dev/null || true; rm -f "$SOCKET"' EXIT
trap 'exit 130' INT TERM
listening_or_gone() { [ -S "$SOCKET" ] || ! kill -0 "$service" 2>/dev/null; }
wait_for 600 listening_or_gone || die "the service did not open $SOCKET within 60 s"
[ -S "$SOCKET" ] || { tail -5 "$LOG" >&2; die "the service stopped (log: $LOG)"; }

$PYTHON - "$SOCKET" <<'EOF'
import socket, struct, sys

XML_MAGIC = 0x58445358  # "XSDX"
PING, PONG, MSA_TOKEN_REQUEST, MSA_TOKEN_RESPONSE = 1, 2, 3, 4
GAME_LICENSE_REQUEST, GAME_LICENSE_RESPONSE = 100, 101
E_FAIL = 0x80004005

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(sys.argv[1])

def recv_exact(n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise SystemExit("FAIL: the service closed the connection")
        data += chunk
    return data

def call(message_type, payload):
    s.sendall(struct.pack("<IHH", XML_MAGIC, message_type, len(payload)) + payload)
    magic, reply_type, size = struct.unpack("<IHH", recv_exact(8))
    return magic, reply_type, recv_exact(size)

magic, reply, body = call(PING, b"macrock-ping")
assert (magic, reply, body) == (XML_MAGIC, PONG, b"macrock-ping"), (hex(magic), reply, body)
print("ping: PONG with the same payload")

request = (b"<MSATokenRequest><ClientId>0000000000000000</ClientId>"
           b"<MSAFullTrust>true</MSAFullTrust></MSATokenRequest>")
magic, reply, body = call(MSA_TOKEN_REQUEST, request)
assert (magic, reply, body) == (XML_MAGIC, MSA_TOKEN_RESPONSE, b""), (hex(magic), reply, len(body))
print("token request without a signed-in user: empty answer")

# The game license needs the account's Microsoft tokens: without them, a failure (E_FAIL).
request = b"<GameLicenseRequest><StoreId>9NBLGGH2JHXJ</StoreId><Market>US</Market></GameLicenseRequest>"
magic, reply, body = call(GAME_LICENSE_REQUEST, request)
assert (magic, reply) == (XML_MAGIC, GAME_LICENSE_RESPONSE), (hex(magic), reply)
assert b"<Result>%d</Result>" % E_FAIL in body and b"<IsActive>false</IsActive>" in body, body
print("game license without a signed-in user: E_FAIL")

magic, reply, body = call(PING, b"again")
assert (reply, body) == (PONG, b"again")
print("ping after the failed request: still answered")
EOF

before=$(grep -c 'Connection from pid' "$LOG" || true)
XODUS_SOCKET="$SOCKET" XGR_XODUS_NO_ACCOUNT=1 GTEST_FILTER='XNetworkingTests.*:XSystemTests.*:XUserNoAccountTests.*' \
  "$TESTS/../xgameruntime/run.sh" "$RUNTIME"
after=$(grep -c 'Connection from pid' "$LOG" || true)
info "service: $((after - before)) connection(s) from the runtime under Wine"
[ "$after" -gt "$before" ] || die "the runtime never connected to the service (log: $LOG)"
info "Xodus service: protocol and runtime connection passed"
