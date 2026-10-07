#!/bin/sh
# run.sh [RUNTIME]: play Minecraft Bedrock (GDK) on a runtime with D3DMetal.
#
#   GAME              the game folder (Minecraft.Windows.exe, MicrosoftGame.Config)
#   GPTK_LIB          the lib directory of an imported Game Porting Toolkit (D3DMetal)
#   GAMEINPUT_SCRIPT  an installer of GameInput from the game's redistributable, run as
#                     SCRIPT --prefix P --msi M --wineserver W, then --check; it leaves the
#                     registry file P/.standalone-gameinput.reg to import
#   XODUS_SOCKET      a running xodus-service with a signed-in account
#   PREFIX            the Wine prefix, default $ENGINE_WORK/prefix-game, prepared the first time
#   D3DM_MTL4=0       D3DMetal's Metal 3 backend instead of Metal 4
#   MACROCK_FPS_LOG   a file that receives one line of frame times per second
#   GAME_ENV          NAME=value words added to the game's environment
#   LOG_FILTER        an extended grep expression: the log keeps only the lines that match
#   LOG_PIPE          a command that filters the output instead; it must pass "exit status" lines
#
# A new prefix gets the game folder as the runtime's game drive (setup.json's game_drive) and
# GameInput; before every launch prefix-setup.py applies what the runtime declares a prefix needs,
# as the launcher will. The output goes to $ENGINE_WORK/game/minecraft-<time>.log: the runtime
# logs no tokens, but raw Wine traces (WINEDEBUG) can. Returns when the game exits.
set -eu
TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTS/../lib.sh"

RUNTIME=${1:-$DIST}
PREFIX=${PREFIX:-$WORK/prefix-game}
LOGS="$WORK/game"
SETUP="$RUNTIME/share/macrock-engine/prefix/setup.json"
require_runtime
[ -f "$SETUP" ] || die "no prefix setup in $RUNTIME"
[ -n "${GAME:-}" ] && [ -f "$GAME/Minecraft.Windows.exe" ] && [ -f "$GAME/MicrosoftGame.Config" ] ||
  die "set GAME to the game folder"
[ -n "${GPTK_LIB:-}" ] && [ -f "$GPTK_LIB/external/libd3dshared.dylib" ] ||
  die "set GPTK_LIB to the lib directory of an imported Game Porting Toolkit"
[ -n "${XODUS_SOCKET:-}" ] && [ -S "$XODUS_SOCKET" ] || die "set XODUS_SOCKET to a running xodus-service"
if pgrep -qf 'Minecraft.Windows.exe'; then die "Minecraft is already running"; fi
OVERRIDES=$(json_get "$SETUP" dll_overrides)
DRIVE=$(json_get "$SETUP" game_drive)
mkdir -p "$LOGS"

run_game() {
  # shellcheck disable=SC2086
  d3dmetal_env "$GPTK_LIB" WINEDLLOVERRIDES="$OVERRIDES;d3d12,d3d11,d3d10,dxgi=b;nvapi64=" ROSETTA_ADVERTISE_AVX=1 \
    XODUS_SOCKET="$XODUS_SOCKET" XGAMERUNTIME_LOG_LEVEL="${XGAMERUNTIME_LOG_LEVEL:-fixme}" \
    MACROCK_WINDOW_TITLE_SUFFIX=" (macrock-engine)" ${MACROCK_FPS_LOG:+MACROCK_FPS_LOG="$MACROCK_FPS_LOG"} \
    ${GAME_ENV:-} "$RUNTIME/bin/wine" "$@"
}

if [ ! -f "$PREFIX/.macrock-game" ]; then
  [ -n "${GAMEINPUT_SCRIPT:-}" ] && [ -f "$GAMEINPUT_SCRIPT" ] || die "set GAMEINPUT_SCRIPT to a GameInput installer"
  ensure_prefix
  ln -sfn "$GAME" "$PREFIX/dosdevices/$DRIVE"
  setup="$LOGS/prefix-gameinput.log"
  info "Installing GameInput into $PREFIX (log: $setup)"
  msi="$GAME/Installers/GameInputRedist.msi"
  /usr/bin/python3 "$GAMEINPUT_SCRIPT" --prefix "$PREFIX" --msi "$msi" --wineserver "$RUNTIME/bin/wineserver" > "$setup" 2>&1
  run_wine reg import "Z:$(printf '%s' "$PREFIX/.standalone-gameinput.reg" | tr / '\\')" >> "$setup" 2>&1
  wineserver -w
  /usr/bin/python3 "$GAMEINPUT_SCRIPT" --prefix "$PREFIX" --msi "$msi" --check >> "$setup" 2>&1
  touch "$PREFIX/.macrock-game"
fi
$PYTHON "$TESTS/prefix-setup.py" "$RUNTIME" "$PREFIX"

log_filter() {
  if [ -n "${LOG_PIPE:-}" ]; then sh -c "$LOG_PIPE"
  elif [ -n "${LOG_FILTER:-}" ]; then grep -a --line-buffered -E "$LOG_FILTER|^exit status"
  else cat
  fi
}

log="$LOGS/minecraft-$(date +%Y%m%d-%H%M%S).log"
game="$(printf '%s' "$DRIVE" | tr '[:lower:]' '[:upper:]')\\Minecraft.Windows.exe"
info "Starting Minecraft on $RUNTIME (log: $log)"
(cd "$GAME" && { status=0; run_game "$game" 2>&1 || status=$?; echo "exit status $status"; }) | log_filter > "$log" 2>&1 ||
  true
status=$(sed -n 's/^exit status //p' "$log" | tail -n 1)
wineserver -w
info "Minecraft exited with status ${status:-unknown}"
