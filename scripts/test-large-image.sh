#!/bin/zsh
# Copyright (c) 2026 The Commercial Art Lab
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

if [[ "$#" != 1 ]]; then
  print -u2 "Usage: scripts/test-large-image.sh /path/to/input-image"
  exit 2
fi
ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
LARGE_TEST_ARCH="${RESIZE_LARGE_TEST_ARCH:-$(uname -m)}"
case "$LARGE_TEST_ARCH" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported test architecture: $LARGE_TEST_ARCH"; exit 2 ;;
esac
LARGE_TEST_BINARY="$BUILD/resize-large-tests-$LARGE_TEST_ARCH"
mkdir -p "$BUILD/module-cache" "$BUILD/large-image-output"
xcrun swiftc -O -target "$LARGE_TEST_ARCH-apple-macosx12.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Sources/CropSelection.swift" "$ROOT/Sources/ResizeEngine.swift" "$ROOT/Sources/TextWatermark.swift" "$ROOT/Tests/LargeImage.swift" \
  -framework AppKit -framework Accelerate -framework ImageIO -framework CoreText \
  -o "$LARGE_TEST_BINARY"
if [[ "$LARGE_TEST_ARCH" == "$(uname -m)" ]]; then
  "$LARGE_TEST_BINARY" "$1" "$BUILD/large-image-output"
else
  /usr/bin/arch "-$LARGE_TEST_ARCH" "$LARGE_TEST_BINARY" "$1" "$BUILD/large-image-output"
fi
