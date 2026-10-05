#!/bin/bash
# Copyright (c) 2026 The Commercial Art Lab
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/Image Resize.app"
DIST_DIR="$ROOT_DIR/dist"
SKIP_BUILD=false

if [[ $# -eq 1 && "$1" == "--skip-build" ]]; then
    SKIP_BUILD=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--skip-build]" >&2
    exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "NOTARY_PROFILE requires DEVELOPER_ID_APPLICATION." >&2
    exit 1
fi

if [[ "$SKIP_BUILD" == false ]]; then
    "$ROOT_DIR/scripts/build.sh"
fi
if [[ ! -d "$APP_PATH" ]]; then
    echo "Missing application bundle. Run scripts/build.sh first." >&2
    exit 1
fi
BUNDLED_LICENSE="$APP_PATH/Contents/Resources/LICENSE.txt"
BUNDLED_NOTICE="$APP_PATH/Contents/Resources/NOTICE.txt"
BUNDLED_SOURCE="$APP_PATH/Contents/Resources/Source.zip"
for REQUIRED_FILE in "$BUNDLED_LICENSE" "$BUNDLED_NOTICE" "$BUNDLED_SOURCE"; do
    if [[ ! -f "$REQUIRED_FILE" || -L "$REQUIRED_FILE" ]]; then
        echo "Missing bundled license, notice or corresponding source. Run scripts/build.sh first." >&2
        exit 1
    fi
done
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/ImageResize" -verify_arch arm64 x86_64
/usr/bin/unzip -tq "$BUNDLED_SOURCE"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Application version is not valid for packaging." >&2
    exit 1
fi
DMG_PATH="$DIST_DIR/Image Resize-$APP_VERSION-universal.dmg"
SOURCE_ARCHIVE_NAME="Image Resize-$APP_VERSION-source.zip"
SOURCE_ARCHIVE_PATH="$DIST_DIR/$SOURCE_ARCHIVE_NAME"
mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Image Resize.app"
# The disk image contains only the app. Keep the matching source and notices
# inside its signed bundle and as separate distribution files.
cp "$BUNDLED_SOURCE" "$SOURCE_ARCHIVE_PATH"
cp "$BUNDLED_LICENSE" "$DIST_DIR/LICENSE.txt"
cp "$BUNDLED_NOTICE" "$DIST_DIR/NOTICE.txt"

echo "Creating universal installer disk image…"
/usr/bin/hdiutil create \
    -volname "Image Resize" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -fs HFS+ \
    -ov "$DMG_PATH"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    /usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "DMG is not notarized. To notarize, set DEVELOPER_ID_APPLICATION and NOTARY_PROFILE."
fi

/usr/bin/hdiutil verify "$DMG_PATH"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" "$SOURCE_ARCHIVE_NAME" LICENSE.txt NOTICE.txt > SHA256SUMS
    /usr/bin/shasum -a 256 -c SHA256SUMS
)
echo "Installer: $DMG_PATH"
echo "Corresponding source: $SOURCE_ARCHIVE_PATH"
echo "Checksum: $DIST_DIR/SHA256SUMS"
echo "Install by dragging Image Resize into Applications."
