#!/bin/bash
# Copyright © 2026 Jesse Holden.  SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Matcha.app. Requires only the Xcode Command Line Tools (swiftc).
# No Xcode project, no package manager, no dependencies.
#
#   ./build.sh              build into ./build/Matcha.app
#   ./build.sh --install    ...then copy it to ~/Applications (or $INSTALL_DIR)
#
# The version comes from the nearest git tag (e.g. v1.9 -> 1.9). Override with
# MATCHA_VERSION=1.2.3 ./build.sh. Building never modifies a tracked file:
# the version is stamped into the *bundle's* Info.plist, not the one in git.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

BUILD_DIR="build"
APP="$BUILD_DIR/Matcha.app"

# ---------------------------------------------------------------- version
# Precedence: explicit override -> git tag -> VERSION file -> unknown.
if [[ -n "${MATCHA_VERSION:-}" ]]; then
  VERSION="$MATCHA_VERSION"
elif desc=$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null); then
  # v1.9 -> 1.9 ; v1.9-3-gabc123 -> 1.9.3 (3 commits past the tag)
  VERSION=$(sed -E 's/^v//; s/-([0-9]+)-g[0-9a-f]+/.\1/' <<<"$desc")
elif [[ -f VERSION ]]; then
  VERSION=$(<VERSION)                       # source tarball: no git metadata
else
  VERSION="0.0.0-unknown"
fi

# CFBundleVersion must increase monotonically; commit count does, dates mostly do.
BUILD_NUM=$(git rev-list --count HEAD 2>/dev/null || date +%y%m%d)

echo "Version: ${VERSION} (build ${BUILD_NUM})"

# ---------------------------------------------------------------- icon
# AppIcon.png (1024x1024) is the source artwork; scale it into a .icns.
echo "Building AppIcon.icns..."
rm -rf "$BUILD_DIR/AppIcon.iconset" && mkdir -p "$BUILD_DIR/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -s format png -z "$s" "$s"             AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_${s}x${s}.png"    >/dev/null
  sips -s format png -z "$((s*2))" "$((s*2))" AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
rm -rf "$BUILD_DIR/AppIcon.iconset"

# ---------------------------------------------------------------- compile
echo "Compiling..."
xcrun swiftc -O main.swift -o "$BUILD_DIR/Matcha"

# ---------------------------------------------------------------- assemble
echo "Assembling Matcha.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/Matcha" "$APP/Contents/MacOS/Matcha"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp AppIcon.png               "$APP/Contents/Resources/AppIcon.png"

# Stamp the version into the bundle only — the tracked Info.plist stays clean.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}"          "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- sign
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP  (version ${VERSION})"

# ---------------------------------------------------------------- install
if (( INSTALL )); then
  dest="${INSTALL_DIR:-$HOME/Applications}"
  [[ -d "$dest" ]] || dest="/Applications"
  echo "Installing to $dest/Matcha.app..."
  rm -rf "$dest/Matcha.app"
  ditto "$APP" "$dest/Matcha.app"
  echo "Installed. (Quit and relaunch Matcha if it was running.)"
fi
