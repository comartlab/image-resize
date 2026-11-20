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

if [[ -n "${NOTARY_PROFILE:-}" && ( -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${DEVELOPER_ID_INSTALLER:-}" ) ]]; then
    echo "NOTARY_PROFILE requires DEVELOPER_ID_APPLICATION and DEVELOPER_ID_INSTALLER." >&2
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
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    # A previous ad hoc build passes ordinary signature verification.
    /usr/bin/codesign --verify --test-requirement '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP_PATH"
fi
/usr/bin/lipo "$APP_PATH/Contents/MacOS/ImageResize" -verify_arch arm64 x86_64
/usr/bin/unzip -tq "$BUNDLED_SOURCE"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ || ! "$MINIMUM_MACOS" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Application or minimum macOS version is not valid for packaging." >&2
    exit 1
fi
DMG_PATH="$DIST_DIR/Image Resize-$APP_VERSION-universal.dmg"
SOURCE_ARCHIVE_NAME="Image Resize-$APP_VERSION-source.zip"
SOURCE_ARCHIVE_PATH="$DIST_DIR/$SOURCE_ARCHIVE_NAME"
mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

PAYLOAD="$STAGING_DIR/payload"
INSTALLER_RESOURCES="$STAGING_DIR/resources"
IMAGE_CONTENTS="$STAGING_DIR/image"
mkdir -p "$PAYLOAD" "$INSTALLER_RESOURCES" "$IMAGE_CONTENTS"
/usr/bin/ditto "$APP_PATH" "$PAYLOAD/Image Resize.app"

# Keep the installer text separate from the verbatim license in the app.
cat > "$INSTALLER_RESOURCES/License.txt" <<'EOF'
Image Resize
Copyright (c) 2026 The Commercial Art Lab

Image Resize is licensed under the GNU General Public License, version 3
or, at your option, any later version. Choose Agree to accept the terms for
this installation and acknowledge the warranty disclaimer and limitation
of liability below.

Image Resize is provided as is, without warranty to the extent permitted by
applicable law. The Commercial Art Lab and the other copyright holders are
liable for damages arising from use of or inability to use the program only
if required by applicable law or agreed to in writing. Sections 15 through
17 of the license below contain the full warranty and liability terms.

EOF
cat "$BUNDLED_LICENSE" >> "$INSTALLER_RESOURCES/License.txt"

cat > "$STAGING_DIR/Components.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key><string>Image Resize.app</string>
        <key>BundleIsRelocatable</key><false/>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleIsVersionChecked</key><true/>
        <key>BundleOverwriteAction</key><string>upgrade</string>
    </dict>
</array>
</plist>
EOF
/usr/bin/pkgbuild --root "$PAYLOAD" --component-plist "$STAGING_DIR/Components.plist" \
    --install-location /Applications --identifier com.cjohnson.imageresize.installer \
    --version "$APP_VERSION" "$STAGING_DIR/ImageResize.pkg"

cat > "$STAGING_DIR/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Image Resize</title>
    <license file="License.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="$MINIMUM_MACOS"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="app"/></choices-outline>
    <choice id="app" visible="false"><pkg-ref id="com.cjohnson.imageresize.installer"/></choice>
    <pkg-ref id="com.cjohnson.imageresize.installer">ImageResize.pkg</pkg-ref>
</installer-gui-script>
EOF

PRODUCT_ARGS=(--distribution "$STAGING_DIR/Distribution.xml" --resources "$INSTALLER_RESOURCES"
    --package-path "$STAGING_DIR")
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    PRODUCT_ARGS+=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
else
    echo "Installer package is unsigned. Set DEVELOPER_ID_INSTALLER to sign it."
fi
/usr/bin/productbuild "${PRODUCT_ARGS[@]}" "$IMAGE_CONTENTS/Install Image Resize.pkg"

echo "Creating universal installer disk image…"
STAGED_DMG="$STAGING_DIR/$(basename "$DMG_PATH")"
/usr/bin/hdiutil create \
    -volname "Image Resize" \
    -srcfolder "$IMAGE_CONTENTS" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -fs HFS+ \
    "$STAGED_DMG"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    /usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$STAGED_DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$STAGED_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGED_DMG"
    xcrun stapler validate "$STAGED_DMG"
else
    echo "DMG is not notarized. To notarize, set DEVELOPER_ID_APPLICATION, DEVELOPER_ID_INSTALLER and NOTARY_PROFILE."
fi

/usr/bin/hdiutil verify "$STAGED_DMG"
mv "$STAGED_DMG" "$DMG_PATH"
cp "$BUNDLED_SOURCE" "$SOURCE_ARCHIVE_PATH"
cp "$BUNDLED_LICENSE" "$DIST_DIR/LICENSE.txt"
cp "$BUNDLED_NOTICE" "$DIST_DIR/NOTICE.txt"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" "$SOURCE_ARCHIVE_NAME" LICENSE.txt NOTICE.txt > SHA256SUMS
    /usr/bin/shasum -a 256 -c SHA256SUMS
)
echo "Installer: $DMG_PATH"
echo "Corresponding source: $SOURCE_ARCHIVE_PATH"
echo "Checksum: $DIST_DIR/SHA256SUMS"
echo "Open Install Image Resize.pkg from the DMG and review the license in macOS Installer."
