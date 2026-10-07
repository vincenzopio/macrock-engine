#!/bin/sh
# release.sh: put the release package.sh wrote into a draft GitHub release, v<version>.
#
# The release must be clean (package.sh without --dev, at HEAD), pass tests/bundle/check.sh, and
# HEAD must be on GitHub already: the release's tag is created at that commit when the draft is
# published. Uploads the two archives, their .sha256, index.json and SOURCES.md. The draft stays
# private until it is published on GitHub (or with `gh release edit v<version> --draft=false`).
# Needs the GitHub CLI, signed in (gh auth login).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"

OUT="$WORK/packages"
INDEX="$OUT/index.json"
TAG="v$VERSION"
command -v gh >/dev/null 2>&1 || die "the GitHub CLI is required: brew install gh, then gh auth login"
[ -f "$INDEX" ] || die "no release in $OUT; run package.sh"

head=$(git -C "$ROOT" rev-parse HEAD)
[ "$(json_get "$INDEX" dirty)" = false ] || die "the release was packaged with --dev"
[ "$(json_get "$INDEX" version)" = "$VERSION" ] || die "the release is $(json_get "$INDEX" version), VERSION is $VERSION"
[ "$(json_get "$INDEX" engine_commit)" = "$head" ] || die "the release was not packaged at HEAD; run package.sh"
git -C "$ROOT" fetch --quiet origin
git -C "$ROOT" merge-base --is-ancestor "$head" origin/main || die "HEAD is not on GitHub's main yet; push it first"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then die "$REPO already has a release $TAG"; fi
"$ROOT/tests/bundle/check.sh" "$OUT" || die "tests/bundle/check.sh failed"

bundle=$(json_get "$INDEX" bundle.file)
helper=$(json_get "$INDEX" helper.file)
info "Creating the draft release $TAG on $REPO"
gh release create "$TAG" --repo "$REPO" --draft --target "$head" --title "macrock-engine $VERSION" --notes-file - \
  "$OUT/$bundle" "$OUT/$bundle.sha256" "$OUT/$helper" "$OUT/$helper.sha256" "$INDEX" \
  "$OUT/macrock-engine-$VERSION.bundle/Contents/Resources/runtime/share/doc/macrock-engine/SOURCES.md" <<EOF
macrock-engine $VERSION (build $(json_get "$INDEX" build)), from commit $head.

- \`$bundle\`: the runtime, a sealed macOS bundle (Wine $(pin wine ref) with our patches, xgameruntime). SHA-256 $(json_get "$INDEX" bundle.sha256).
- \`$helper\`: xodus-service for the launcher's app bundle, with its licenses. SHA-256 $(json_get "$INDEX" helper.sha256).
- \`index.json\`: what a launcher reads first (sizes, SHA-256, requirements).
- \`SOURCES.md\`: the upstream commits and patches the runtime was built from.

Requires an Apple Silicon Mac with macOS $(json_get "$INDEX" requires.macos) and Rosetta 2, Apple's Game Porting Toolkit $(json_get "$INDEX" requires.gptk) (not
included) and a Microsoft account that owns Minecraft for Windows. Experimental: see the README's
"What works" and docs/known-issues.md.
EOF
info "Draft ready: check it on GitHub, then publish it there or with: gh release edit $TAG --repo $REPO --draft=false"
