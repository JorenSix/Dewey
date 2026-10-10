#!/usr/bin/env bash
# Build Dewey and package it as a single distributable disk image: build/Dewey.dmg
# (Dewey.app + an Applications shortcut). The .app is assembled in a temp dir and not kept.
# Usage: scripts/package-dmg.sh        (SCRATCH=.build-x to use another SwiftPM scratch path)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DMG="$ROOT/build/Dewey.dmg"

OUT="$STAGE/Dewey.app" "$ROOT/scripts/bundle.sh"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/build"
rm -f "$DMG"
hdiutil create -volname "Dewey" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
