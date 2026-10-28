// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum WatermarkKind: String, CaseIterable {
    case text, png
}

enum WatermarkCorner: String, CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight
}

enum PNGWatermark {
    /// Decode once on the background worker; the immutable image can then be
    /// shared by every export and preview in a batch.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ResizeError.invalidSettings("Choose a readable, single-image PNG watermark.")
        }
        return image
    }

    static func validate(image: CGImage?, size: Double, padding: Double, strength: Double) throws {
        guard image != nil else { throw ResizeError.invalidSettings("Choose a PNG watermark.") }
        guard size.isFinite, size > 0, size <= 1 else {
            throw ResizeError.invalidSettings("Watermark size must be greater than 0 and at most 100 percent.")
        }
        guard padding.isFinite, padding >= 0, padding < 0.5 else {
            throw ResizeError.invalidSettings("Watermark padding must be between 0 and 50 percent, excluding 50.")
        }
        guard strength.isFinite, (0...1).contains(strength) else {
            throw ResizeError.invalidSettings("Watermark strength must be between 0 and 100 percent.")
        }
    }

    /// Coordinates are output pixels with CoreGraphics' bottom-left origin.
    /// Size is the logo's longest edge relative to the output's shorter edge;
    /// padding uses the same reference, with a final fit inside the inset.
    static func frame(image: CGImage, width: Int, height: Int, corner: WatermarkCorner,
                      size: Double, padding: Double) throws -> CGRect {
        try validate(image: image, size: size, padding: padding, strength: 1)
        guard width > 0, height > 0 else { throw ResizeError.invalidSettings("Image dimensions must be positive.") }
        let w = CGFloat(width), h = CGFloat(height), shorter = min(w, h)
        let inset = shorter * CGFloat(padding)
        let scale = min(shorter * CGFloat(size) / CGFloat(max(image.width, image.height)),
                        min((w - 2 * inset) / CGFloat(image.width), (h - 2 * inset) / CGFloat(image.height)))
        let logoWidth = CGFloat(image.width) * scale, logoHeight = CGFloat(image.height) * scale
        let right = corner == .upperRight || corner == .lowerRight
        let upper = corner == .upperLeft || corner == .upperRight
        return CGRect(x: right ? w - inset - logoWidth : inset,
                      y: upper ? h - inset - logoHeight : inset, width: logoWidth, height: logoHeight)
    }

    static func draw(image: CGImage, in context: CGContext, width: Int, height: Int,
                     corner: WatermarkCorner, size: Double, padding: Double, strength: Double) throws {
        try validate(image: image, size: size, padding: padding, strength: strength)
        guard strength > 0 else { return }
        let rect = try frame(image: image, width: width, height: height, corner: corner, size: size, padding: padding)
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.normal)
        context.setAlpha(CGFloat(strength))
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
}
