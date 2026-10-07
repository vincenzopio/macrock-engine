#!/bin/sh
# run.sh [RUNTIME]: sign in for real through xgameruntime and the Xodus service.
#
# Runs xgameruntime's XUserLiveTests: XUserAddAsync gets MSA tickets from the Xodus service at
# XODUS_SOCKET (which must have a signed-in account, e.g. one added with
# `XODUS_KEYCHAIN_SERVICE=... $ENGINE_WORK/bin/xodus-cli login`) and signs in to Xbox Live
# through SISU; XUserGetTokenAndSignature then gets tokens that profile.xboxlive.com,
# title.mgt.xboxlive.com and (for Minecraft) Realms accept. The tests need the title's own
# MicrosoftGame.config for its title and MSA app ids: GAME_CONFIG. They print no personal data:
# statuses, counts and lengths.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
BIN="$XGR_BUILD/bin"
LIVE="$WORK/xuser-live"
PREFIX="$WORK/prefix-probe"
[ -n "${XODUS_SOCKET:-}" ] && [ -S "$XODUS_SOCKET" ] || die "set XODUS_SOCKET to a running xodus-service"
[ -n "${GAME_CONFIG:-}" ] && [ -f "$GAME_CONFIG" ] || die "set GAME_CONFIG to the title's MicrosoftGame.config"
[ -f "$BIN/test_xgameruntime.exe" ] || die "no tests in $BIN; run build-xgameruntime.sh"
require_runtime
ensure_prefix

rm -rf "$LIVE"
mkdir -p "$LIVE"
cp "$BIN/test_xgameruntime.exe" "$BIN/xgameruntime.dll" "$LIVE/"
cp "$GAME_CONFIG" "$LIVE/MicrosoftGame.config"

log="$LIVE/tests.log"
info "Signing in through $XODUS_SOCKET (log: $log)"
status=0
(cd "$LIVE" && wine_env XODUS_SOCKET="$XODUS_SOCKET" XGR_LIVE_XBOX=1 \
  GTEST_FILTER='XUserLiveTests.*:XStoreLiveTests.*' "$RUNTIME/bin/wine" test_xgameruntime.exe) > "$log" 2>&1 || status=$?
wineserver -k 2>/dev/null || true
tr -d '\r' < "$log" | grep -E '^\[(   LIVE   |  PASSED  |  FAILED  |  SKIPPED )\]|\(warning\)|\(error\)' || true
[ "$status" = 0 ] || die "live sign-in failed (exit $status; see $log)"
