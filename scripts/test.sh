#!/bin/zsh
# Copyright (c) 2026 The Commercial Art Lab
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
TEST_ARCH="${RESIZE_TEST_ARCH:-$(uname -m)}"
case "$TEST_ARCH" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported test architecture: $TEST_ARCH"; exit 2 ;;
esac
TEST_BINARY="$BUILD/resize-tests-$TEST_ARCH"
mkdir -p "$BUILD/module-cache"
xcrun swiftc -O -target "$TEST_ARCH-apple-macosx12.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Sources/CropSelection.swift" "$ROOT/Sources/ResizeEngine.swift" "$ROOT/Sources/TextWatermark.swift" \
  "$ROOT/Sources/ImageQueue.swift" "$ROOT/Sources/ImageDiscovery.swift" "$ROOT/Sources/OutputEstimateStore.swift" \
  "$ROOT/Tests/LayerFixtures.swift" "$ROOT/Tests/main.swift" \
  -framework AppKit -framework Accelerate -framework ImageIO -framework CoreText -framework UniformTypeIdentifiers \
  -o "$TEST_BINARY"
if [[ "$TEST_ARCH" == "$(uname -m)" ]]; then
  "$TEST_BINARY" "$BUILD/test-work"
else
  /usr/bin/arch "-$TEST_ARCH" "$TEST_BINARY" "$BUILD/test-work"
fi
