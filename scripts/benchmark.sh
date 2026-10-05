#!/bin/zsh
# Copyright (c) 2026 The Commercial Art Lab
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
BENCHMARK_ARCH="${RESIZE_BENCHMARK_ARCH:-$(uname -m)}"
case "$BENCHMARK_ARCH" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported benchmark architecture: $BENCHMARK_ARCH"; exit 2 ;;
esac
BENCHMARK_BINARY="$BUILD/resize-benchmark-$BENCHMARK_ARCH"
mkdir -p "$BUILD/module-cache"
xcrun swiftc -O -target "$BENCHMARK_ARCH-apple-macosx12.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Sources/CropSelection.swift" "$ROOT/Sources/ResizeEngine.swift" "$ROOT/Sources/TextWatermark.swift" "$ROOT/Tests/Benchmark.swift" \
  -framework AppKit -framework Accelerate -framework ImageIO -framework CoreText \
  -o "$BENCHMARK_BINARY"
if [[ "$BENCHMARK_ARCH" == "$(uname -m)" ]]; then
  "$BENCHMARK_BINARY" "$BUILD/benchmark-work"
else
  /usr/bin/arch "-$BENCHMARK_ARCH" "$BENCHMARK_BINARY" "$BUILD/benchmark-work"
fi
