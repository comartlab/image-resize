// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

enum CropAspect: String, CaseIterable, Codable {
    case free, square, portrait9x16, landscape16x9, portrait2x3, landscape3x2, portrait4x5, landscape5x4

    var title: String {
        switch self {
        case .free: return "Freehand"
        case .square: return "1:1"
        case .portrait9x16: return "9:16"
        case .landscape16x9: return "16:9"
        case .portrait2x3: return "2:3"
        case .landscape3x2: return "3:2"
        case .portrait4x5: return "4:5"
        case .landscape5x4: return "5:4"
        }
    }

    var ratio: Double? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .portrait9x16: return 9.0 / 16
        case .landscape16x9: return 16.0 / 9
        case .portrait2x3: return 2.0 / 3
        case .landscape3x2: return 3.0 / 2
        case .portrait4x5: return 4.0 / 5
        case .landscape5x4: return 5.0 / 4
        }
    }
}

/// A normalized box in the displayed, EXIF-oriented image. Coordinates begin
/// at the top-left. Fixed ratios fit inside this box, centered on its center.
struct CropSelection: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var aspect: CropAspect

    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1,
         aspect: CropAspect = .free) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.aspect = aspect
    }

    /// Return integer-valued image coordinates, retaining the selected center
    /// as closely as whole pixels allow. A subpixel selection occupies one pixel.
    func pixelRect(width imageWidth: Int, height imageHeight: Int) throws -> CGRect {
        let bounds = try pixelBounds(width: imageWidth, height: imageHeight)
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }

    /// Keep dimensions as integers separately from CGRect: CGFloat cannot
    /// represent every Int near its upper boundary, while planning must not trap.
    func pixelBounds(width imageWidth: Int, height imageHeight: Int)
        throws -> (x: Int, y: Int, width: Int, height: Int) {
        guard imageWidth > 0, imageHeight > 0 else {
            throw ResizeError.invalidSettings("Image dimensions must be positive.")
        }
        let tolerance = 1e-12
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= -tolerance, y >= -tolerance, width > 0, height > 0,
              x <= 1 + tolerance, y <= 1 + tolerance,
              width <= 1 + tolerance, height <= 1 + tolerance,
              x + width <= 1 + tolerance, y + height <= 1 + tolerance else {
            throw ResizeError.invalidSettings("Choose a crop area inside the image.")
        }
        let left = min(1, max(0, x)), top = min(1, max(0, y))
        let normalizedWidth = min(width, 1 - left)
        let normalizedHeight = min(height, 1 - top)
        guard normalizedWidth > 0, normalizedHeight > 0 else {
            throw ResizeError.invalidSettings("Choose a crop area inside the image.")
        }
        let sourceWidth = Double(imageWidth), sourceHeight = Double(imageHeight)
        let boxWidth = normalizedWidth * sourceWidth
        let boxHeight = normalizedHeight * sourceHeight
        let centerX = (left + normalizedWidth / 2) * sourceWidth
        let centerY = (top + normalizedHeight / 2) * sourceHeight
        var fittedWidth = boxWidth, fittedHeight = boxHeight
        if let ratio = aspect.ratio {
            if boxWidth > boxHeight * ratio { fittedWidth = boxHeight * ratio }
            else { fittedHeight = boxWidth / ratio }
        }
        let cropWidth = roundedPixel(fittedWidth, maximum: imageWidth, minimum: 1)
        let cropHeight = roundedPixel(fittedHeight, maximum: imageHeight, minimum: 1)
        let cropX = roundedPixel(centerX - Double(cropWidth) / 2,
                                 maximum: imageWidth - cropWidth, minimum: 0)
        let cropY = roundedPixel(centerY - Double(cropHeight) / 2,
                                 maximum: imageHeight - cropHeight, minimum: 0)
        return (cropX, cropY, cropWidth, cropHeight)
    }

    private func roundedPixel(_ value: Double, maximum: Int, minimum: Int) -> Int {
        let rounded = value.rounded()
        // Double(Int.max) rounds to 2^63; compare before converting to Int.
        if rounded >= Double(maximum) { return maximum }
        if rounded <= Double(minimum) { return minimum }
        return Int(rounded)
    }
}

struct ResizeOutputPlan {
    /// Oriented image coordinates with a top-left origin.
    let cropRect: CGRect
    let cropWidth: Int
    let cropHeight: Int
    let width: Int
    let height: Int
    let skipped: Bool
    let isCropped: Bool
}
