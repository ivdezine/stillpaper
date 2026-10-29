#!/bin/bash
# Builds Stillpaper.app from Stillpaper.swift with swiftc (no Xcode project).
#   bash build.sh            -> build/Stillpaper.app
#   bash build.sh --install  -> also copies it to ~/Applications
# OUT_DIR overrides the output folder (the tests build into a temp folder this way). ARCH picks
# the architecture, which is otherwise this Mac's own (arm64 or x86_64).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT_DIR:-$here/build}"
arch="${ARCH:-$(uname -m)}"
version="1.0.0"
build="$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$here" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$here" status --porcelain -- . 2>/dev/null)" ]; then commit="$commit-dirty"; fi

app="$out/Stillpaper.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

# The target pins the deployment version, so the compile itself proves the macOS 12 minimum below.
swiftc -O -target "$arch-apple-macos12" -o "$app/Contents/MacOS/Stillpaper" "$here/Stillpaper.swift" -framework AppKit -framework WebKit

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ivdezine.stillpaper</string>
  <key>CFBundleName</key><string>Stillpaper</string>
  <key>CFBundleExecutable</key><string>Stillpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>GitCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed; the app still runs" >&2

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Stillpaper.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed: $HOME/Applications/Stillpaper.app (Version $version · build $build ($commit), $arch)"
else
  echo "Built: $app (Version $version · build $build ($commit), $arch)"
fi
