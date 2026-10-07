# Pinned inputs of the macOS build. Change a pin only together with its SHA-256.
# shellcheck shell=sh

MACOS_SDK=27.0
MACOS_DEPLOYMENT_TARGET=27.0

LLVM_MINGW_VERSION=20260616
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz
LLVM_MINGW_SHA256=2cab02a2e964bd4aae981150a45985d07c657cfa8d244959eb9e2dcc5eedd7b1

# Only the x86_64 GnuTLS/FreeType dylib closure is taken from this archive; Wine itself is
# compiled from this tree.
GCENX_URL=https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.8/wine-devel-11.8-osx64.tar.xz
GCENX_SHA256=5c9f0984961ee6289f4f2c4fe751c27f02b6c28855154e3f99b7e2bd8108b620

# xodus-service: the toolchain its Cargo.toml requires (rust-version), installed through rustup.
RUST_TOOLCHAIN=1.98.0

# autoconf regenerates Wine's configure when a patch adds a DLL (tools/make_makefiles).
HOMEBREW_FORMULAE="bison gnutls freetype pkgconf gettext ccache cmake protobuf rustup autoconf"

# Releases: the GitHub repository they are published in, and the Game Porting Toolkit major
# version whose D3DMetal the runtime is built for (the user imports it).
REPO=vincenzopio/macrock-engine
GPTK_REQUIRED=4
