#!/bin/sh
# run.sh [RUNTIME]: play Minecraft (tests/game/run.sh) and capture what its HTTP requests were
# and how they were answered: method, host, path without query, status (see sanitize.py).
#
# WinHTTP's trace (WINEDEBUG=+winhttp) goes through sanitize.py in memory and never reaches the
# disk raw. The capture is $ENGINE_WORK/http-capture/<time>/http.txt (and http.json); the game
# log keeps xgameruntime's lines only. The game runner's variables apply.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

CAPTURE_OUT="$WORK/http-capture/$(date +%Y%m%d-%H%M%S)"
CAPTURE_SANITIZER="$TESTS/sanitize.py"
export CAPTURE_OUT CAPTURE_SANITIZER
mkdir -p "$CAPTURE_OUT"
info "Capturing HTTP requests into $CAPTURE_OUT/http.txt"
WINEDEBUG=+winhttp LOG_PIPE='/usr/bin/python3 -I "$CAPTURE_SANITIZER" "$CAPTURE_OUT"' "$TESTS/../game/run.sh" "$@"
info "Capture: $CAPTURE_OUT/http.txt"
