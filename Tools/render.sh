#!/bin/bash
# Renders a Markdown file to standalone HTML using the extension's own renderer,
# then prints the output path. Useful for working on style.css without
# reinstalling the app and restarting Quick Look on every change.
#
#   ./Tools/render.sh Samples/kitchen-sink.md /tmp/preview.html
set -euo pipefail

cd "$(dirname "$0")/.."

BINARY=.build/Build/Products/Release/qm-render

xcodebuild \
  -project QuickMark.xcodeproj \
  -scheme qm-render \
  -configuration Release \
  -derivedDataPath .build \
  -destination 'platform=macOS,arch=arm64' \
  build >/dev/null 2>&1 || {
    echo "Build failed. Run it directly to see why:" >&2
    echo "  xcodebuild -project QuickMark.xcodeproj -scheme qm-render -configuration Release -derivedDataPath .build build" >&2
    exit 1
  }

exec "$BINARY" "$@"
