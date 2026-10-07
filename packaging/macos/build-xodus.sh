#!/bin/sh
# build-xodus.sh [IMPORT OPTIONS]: build xodus-service (native arm64) into $DIST/libexec.
#
# `tools/engine import xodus` generates the tree (options are passed to it), then cargo builds
# the service with the pinned Rust toolchain and the upstream Cargo.lock (--locked). The service
# answers xgameruntime's Xodus IPC on the socket in XODUS_SOCKET, keeping the Microsoft account's
# credentials in the Keychain service named by XODUS_KEYCHAIN_SERVICE. Also builds xodus-cli into
# $WORK/bin, a development tool kept out of the runtime, whose `login` signs an account in there.
# Both are signed with SIGNING_IDENTITY when set (a fixed identity keeps the Keychain's "Always
# Allow" across rebuilds), otherwise ad hoc.
#
# Environment: JOBS (default 4), ENGINE_WORK, SIGNING_IDENTITY. Run build.sh first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

export CARGO_TARGET_DIR="$XODUS_BUILD"
# rustup's proxies (cargo, rustc) select the toolchain given as +<version>; protoc (Homebrew's
# protobuf) compiles the service's protocol definitions.
export PATH="$(brew_prefix rustup)/bin:$(brew_prefix protobuf)/bin:$PATH"
command -v cargo >/dev/null 2>&1 || die "rustup not found; run bootstrap.sh"
cargo "+$RUST_TOOLCHAIN" --version >/dev/null 2>&1 || die "Rust $RUST_TOOLCHAIN not installed; run bootstrap.sh"
[ -x "$DIST/bin/wine" ] || die "no runtime in $DIST; run build.sh first"

"$ENGINE" import xodus "$@"

info "Building xodus-service and xodus-cli (log: $CARGO_TARGET_DIR/build.log)"
mkdir -p "$CARGO_TARGET_DIR"
run_logged "$CARGO_TARGET_DIR/build.log" cargo "+$RUST_TOOLCHAIN" build \
  --manifest-path "$XODUS_SRC/Cargo.toml" --release --locked -j "$JOBS" -p xodus-service -p xodus-cli

for target in "$DIST/libexec/xodus-service" "$WORK/bin/xodus-cli"; do
  mkdir -p "$(dirname "$target")"
  cp "$CARGO_TARGET_DIR/release/$(basename "$target")" "$target"
  codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier "dev.macrock.$(basename "$target")" "$target"
  info "$(basename "$target") -> $target (signed: ${SIGNING_IDENTITY:-ad hoc})"
done
