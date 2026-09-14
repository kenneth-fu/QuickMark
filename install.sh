#!/bin/bash
# Builds QuickMark, installs it to ~/Applications, and re-registers the preview
# extension with Quick Look. Safe to run repeatedly; this is the normal loop
# after changing anything in Sources/.
set -euo pipefail

cd "$(dirname "$0")"

DEST="$HOME/Applications"
PRODUCT=.build/Build/Products/Release/QuickMark.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
EXTENSION_ID=com.puiwaifu.QuickMark.PreviewExtension

if [[ ! -d QuickMark.xcodeproj ]]; then
  echo "==> Generating Xcode project"
  ./generate_project.sh
fi

echo "==> Building"
xcodebuild \
  -project QuickMark.xcodeproj \
  -scheme QuickMark \
  -configuration Release \
  -derivedDataPath .build \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | grep -E "error:|warning: (unused|never)|BUILD" || true

if [[ ! -d "$PRODUCT" ]]; then
  echo "Build did not produce $PRODUCT" >&2
  exit 1
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/QuickMark.app"
cp -R "$PRODUCT" "$DEST/"

# Launch Services happily registers the app sitting in the build directory, and
# then two bundles claim the same identifier. Quick Look picks one of them, and
# when it picks the build copy the extension resolves against a bundle that
# install.sh is about to overwrite. Retire the build copy before registering the
# installed one, or previews silently go blank.
echo "==> Retiring the build copy"
"$LSREGISTER" -u "$PRODUCT" 2>/dev/null || true
rm -rf "$PRODUCT"

echo "==> Registering with Launch Services"
"$LSREGISTER" -f "$DEST/QuickMark.app"

# Quick Look caches extensions aggressively; without this a rebuilt extension
# keeps serving the previous binary.
echo "==> Restarting Quick Look"
killall -9 pkd quicklookd QuickLookUIService 2>/dev/null || true
sleep 2

# PlugInKit only picks the extension up once the containing app has been seen
# running, and it does so asynchronously. Launch the app in the background and
# poll rather than checking once and declaring failure.
echo "==> Waiting for the extension to register"
open -g "$DEST/QuickMark.app" 2>/dev/null || true

for _ in $(seq 1 15); do
  if pluginkit -m -v -i "$EXTENSION_ID" 2>/dev/null | grep -q "$EXTENSION_ID"; then
    pluginkit -m -v -i "$EXTENSION_ID"
    echo
    echo "Done. Select a .md or .env file in Finder and press Space."
    exit 0
  fi
  sleep 1
done

echo "The extension did not register." >&2
echo "Check System Settings > General > Login Items & Extensions > Quick Look." >&2
exit 1
