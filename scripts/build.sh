#!/bin/bash
# Copyright (c) 2026 The Commercial Art Lab
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Image Resize.app"
EXECUTABLE_NAME="ImageResize"
APP_VERSION="${APP_VERSION:-1.12}"
APP_BUILD="${APP_BUILD:-14}"
DEPLOYMENT_TARGET="12.0"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || [[ ! "$APP_BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "APP_VERSION and APP_BUILD must contain numeric version components." >&2
    exit 1
fi

for REQUIRED_FILE in README.md LICENSE NOTICE .gitignore resources/Info.plist resources/AppIcon.icns; do
    if [[ ! -f "$ROOT_DIR/$REQUIRED_FILE" || -L "$ROOT_DIR/$REQUIRED_FILE" ]]; then
        echo "Missing regular source file: $REQUIRED_FILE." >&2
        exit 1
    fi
done
for REQUIRED_DIR in Sources Tests scripts docs; do
    if [[ ! -d "$ROOT_DIR/$REQUIRED_DIR" || -L "$ROOT_DIR/$REQUIRED_DIR" ]]; then
        echo "Missing regular source directory: $REQUIRED_DIR." >&2
        exit 1
    fi
done

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64" "$BUILD_DIR/module-cache/arm64" "$BUILD_DIR/module-cache/x86_64"

# Compile from the same controlled snapshot that is distributed as source.
# Code, tests and build documentation are allowed; generated output, Git data,
# private photo fixtures, symlinks and unrelated resources are never copied.
SOURCE_STAGE="$(mktemp -d "$BUILD_DIR/source-stage.XXXXXX")"
trap 'rm -rf "$SOURCE_STAGE"' EXIT
SOURCE_NAME="Image Resize-$APP_VERSION-source"
SOURCE_ROOT="$SOURCE_STAGE/$SOURCE_NAME"
mkdir -p "$SOURCE_ROOT/Sources" "$SOURCE_ROOT/Tests" "$SOURCE_ROOT/scripts" "$SOURCE_ROOT/docs" "$SOURCE_ROOT/resources"

copy_source_file() {
    local SOURCE_FILE="$1"
    local RELATIVE_FILE="${SOURCE_FILE#"$ROOT_DIR/"}"
    mkdir -p "$SOURCE_ROOT/$(dirname "$RELATIVE_FILE")"
    cp -p "$SOURCE_FILE" "$SOURCE_ROOT/$RELATIVE_FILE"
}

while IFS= read -r -d '' SOURCE_FILE; do
    copy_source_file "$SOURCE_FILE"
done < <(/usr/bin/find -P "$ROOT_DIR/Sources" "$ROOT_DIR/Tests" -type f -name '*.swift' -print0)
while IFS= read -r -d '' SOURCE_FILE; do
    copy_source_file "$SOURCE_FILE"
done < <(/usr/bin/find -P "$ROOT_DIR/scripts" -type f \( -name '*.sh' -o -name '*.swift' \) -print0)
while IFS= read -r -d '' SOURCE_FILE; do
    copy_source_file "$SOURCE_FILE"
done < <(/usr/bin/find -P "$ROOT_DIR/docs" -type f \( -name '*.md' -o -name '*.txt' \) -print0)
for SOURCE_FILE in README.md LICENSE NOTICE .gitignore resources/Info.plist resources/AppIcon.icns; do
    copy_source_file "$ROOT_DIR/$SOURCE_FILE"
done

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$SOURCE_ROOT/resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$SOURCE_ROOT/resources/Info.plist"
# An overridden version remains the default when this source archive is rebuilt.
/usr/bin/sed -i '' \
    -e "s/^APP_VERSION=.*$/APP_VERSION=\"\${APP_VERSION:-$APP_VERSION}\"/" \
    -e "s/^APP_BUILD=.*$/APP_BUILD=\"\${APP_BUILD:-$APP_BUILD}\"/" \
    "$SOURCE_ROOT/scripts/build.sh"
cat > "$SOURCE_ROOT/BUILD-INFO.txt" <<EOF
Image Resize corresponding source
Version: $APP_VERSION
Bundle build: $APP_BUILD
Minimum macOS: $DEPLOYMENT_TARGET
Architectures: arm64, x86_64
License: GPL-3.0-or-later
Rebuild: ./scripts/build.sh
Package: ./scripts/package.sh --skip-build
Only native macOS frameworks are required by the application.
EOF

shopt -s nullglob
SOURCES=("$SOURCE_ROOT"/Sources/*.swift)
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "No Swift sources found in $ROOT_DIR/Sources." >&2
    exit 1
fi

for ARCH in arm64 x86_64; do
    echo "Building $ARCH for macOS ${DEPLOYMENT_TARGET}…"
    "$SWIFTC" \
        -sdk "$SDK_PATH" \
        -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -module-cache-path "$BUILD_DIR/module-cache/$ARCH" \
        -module-name "$EXECUTABLE_NAME" \
        -parse-as-library \
        -O \
        -whole-module-optimization \
        -framework AppKit \
        -framework Accelerate \
        -framework ImageIO \
        -framework CoreGraphics \
        -framework CoreText \
        -framework UniformTypeIdentifiers \
        -framework QuickLookThumbnailing \
        "${SOURCES[@]}" \
        -o "$BUILD_DIR/$ARCH/$EXECUTABLE_NAME"
done

# Recreate only this generated bundle; preserve compiler caches and other outputs.
if [[ -e "$APP_PATH" ]]; then
    rm -rf "$APP_PATH"
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/lipo -create \
    "$BUILD_DIR/arm64/$EXECUTABLE_NAME" \
    "$BUILD_DIR/x86_64/$EXECUTABLE_NAME" \
    -output "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$SOURCE_ROOT/resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SOURCE_ROOT/resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$SOURCE_ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE.txt"
cp "$SOURCE_ROOT/NOTICE" "$APP_PATH/Contents/Resources/NOTICE.txt"
/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent \
    "$SOURCE_ROOT" "$APP_PATH/Contents/Resources/Source.zip"
/usr/bin/unzip -tq "$APP_PATH/Contents/Resources/Source.zip"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
chmod 755 "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    /usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$APP_PATH"
else
    /usr/bin/codesign --force --sign - "$APP_PATH"
    echo "Signed ad hoc. Public distribution requires a Developer ID certificate and notarization."
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch arm64 x86_64
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
echo "Built: $APP_PATH"
