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
if (( $# < 1 )); then
  print -u2 "Usage: scripts/test-layered.sh photoshop-resaved.psd [more PSD files]"
  exit 2
fi
mkdir -p "$BUILD/module-cache"
TEST_BINARY="$BUILD/layer-validation-$TEST_ARCH"
xcrun swiftc -O -target "$TEST_ARCH-apple-macosx12.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Sources/CropSelection.swift" "$ROOT/Sources/ResizeEngine.swift" "$ROOT/Sources/TextWatermark.swift" "$ROOT/Tests/LayerValidation.swift" \
  -framework AppKit -framework Accelerate -framework ImageIO -framework CoreText -o "$TEST_BINARY"
if [[ "$TEST_ARCH" == "$(uname -m)" ]]; then
  "$TEST_BINARY" "$BUILD/photoshop-validation-$TEST_ARCH" "$@"
else
  /usr/bin/arch "-$TEST_ARCH" "$TEST_BINARY" "$BUILD/photoshop-validation-$TEST_ARCH" "$@"
fi
