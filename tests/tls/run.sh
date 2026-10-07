#!/bin/sh
# run.sh [RUNTIME]: check that the runtime's WinHTTP rejects bad server certificates.
#
# See winhttp-tls-probe.c: HTTPS requests to badssl.com (needs the network); the valid host must
# be accepted, the expired, wrong-host, self-signed and untrusted-root ones rejected. The probe is
# built with llvm-mingw into $ENGINE_WORK/probes; the Wine prefix is $ENGINE_WORK/prefix-probe.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
PREFIX="$WORK/prefix-probe"
require_runtime
build_probe winhttp-tls-probe -lwinhttp
ensure_prefix

status=0
log="$WORK/probes/winhttp-tls.log"
run_wine "$WORK/probes/winhttp-tls-probe.exe" > "$log" 2>&1 || status=1
tr -d '\r' < "$log" | grep -E '^(ok|BAD)' || status=1
wineserver -k 2>/dev/null || true
[ "$status" = 0 ] || die "WinHTTP accepted a bad certificate or rejected a good one"
info "TLS probe: WinHTTP validates server certificates"
