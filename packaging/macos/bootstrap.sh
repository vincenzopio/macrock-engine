#!/bin/sh
# bootstrap.sh: install the build prerequisites. Idempotent.
#
# Homebrew formulae for headers and build tools, plus the pinned llvm-mingw (the PE half of
# Wine) and the Gcenx archive (x86_64 GnuTLS/FreeType). Set LLVM_MINGW or GCENX_ARCHIVE to
# reuse copies you already have instead of downloading them.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

[ -x /opt/homebrew/bin/brew ] || die "Homebrew is required: https://brew.sh"
xcode-select -p >/dev/null 2>&1 || die "Command Line Tools are required: xcode-select --install"
xcrun --sdk "macosx$MACOS_SDK" --show-sdk-path >/dev/null 2>&1 ||
  die "macOS $MACOS_SDK SDK not found; install the matching Command Line Tools"

missing=
for formula in $HOMEBREW_FORMULAE; do
  /opt/homebrew/bin/brew list --formula "$formula" >/dev/null 2>&1 || missing="$missing $formula"
done
if [ -n "$missing" ]; then
  info "Installing Homebrew formulae:$missing"
  # shellcheck disable=SC2086
  /opt/homebrew/bin/brew install $missing
fi

if [ ! -x "$MINGW_CC" ]; then
  archive="$DOWNLOADS/$(basename "$LLVM_MINGW_URL")"
  fetch "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256" "$archive"
  info "Extracting llvm-mingw $LLVM_MINGW_VERSION"
  rm -rf "$LLVM_MINGW.part"
  mkdir -p "$LLVM_MINGW.part"
  tar -xJf "$archive" -C "$LLVM_MINGW.part" --strip-components 1
  mv "$LLVM_MINGW.part" "$LLVM_MINGW"
fi

fetch "$GCENX_URL" "$GCENX_SHA256" "$GCENX_ARCHIVE"

rustup="$(brew_prefix rustup)/bin"
if ! "$rustup/cargo" "+$RUST_TOOLCHAIN" --version >/dev/null 2>&1; then
  info "Installing Rust $RUST_TOOLCHAIN"
  "$rustup/rustup" toolchain install "$RUST_TOOLCHAIN" --profile minimal
fi
info "Prerequisites ready."
