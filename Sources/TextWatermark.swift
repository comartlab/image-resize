// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import CoreText

/// The same native text treatment is used for export and preview. Positive
/// CoreText stroke widths draw hollow glyphs; the original string is shaped
/// without changing its capitalization or Unicode characters.
enum TextWatermark {
    static let maximumTextLength = 8192

    static func validate(_ text: String, strength: Double = 0.25) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResizeError.invalidSettings("Enter watermark text.")
        }
        guard text.utf16.count <= maximumTextLength else {
            throw ResizeError.invalidSettings("Watermark text is too long. Use shorter text.")
        }
        guard strength.isFinite, (0...1).contains(strength) else {
            throw ResizeError.invalidSettings("Watermark strength must be between 0 and 100 percent.")
        }
    }

    /// Draw into a CoreGraphics context whose coordinates are measured in
    /// output pixels. The caller retains its color profile and pixel precision.
    static func draw(text: String, in context: CGContext, width: Int, height: Int,
                     strength: Double = 0.25) throws {
        try validate(text, strength: strength)
        guard strength > 0, width > 0, height > 0 else { return }
        let grayOpacity = CGFloat(strength)
        let whiteOpacity = grayOpacity * (0.10 / 0.13)
        let w = CGFloat(width), h = CGFloat(height)
        let shorter = min(w, h)
        let angle = CGFloat.pi / 6
        let rotatedWidth = w * cos(angle) + h * sin(angle)
        let rotatedHeight = w * sin(angle) + h * cos(angle)
        let strings = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)

        var fontSize = max(0.25, shorter * 0.05625)
        var font = CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, fontSize, nil)
        let initial = strings.map { line($0, font: font, stroke: 0.9, color: 0.42) }
        let initialWidth = initial.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        let initialHeight = CGFloat(strings.count) * fontSize * 1.2
        let fit = min(1, min(rotatedWidth * 0.85 / max(1, initialWidth),
                             shorter * 0.18 / max(0.25, initialHeight)))
        fontSize *= fit
        font = CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, fontSize, nil)
        let gray = strings.map { line($0, font: font, stroke: 0.9, color: 0.42) }
        let white = strings.map { line($0, font: font, stroke: 1.5, color: 1) }
        let lengths = gray.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let textWidth = lengths.max() ?? 0
        let lineHeight = fontSize * 1.2
        let blockHeight = CGFloat(strings.count) * lineHeight

        // Normal photographs use 360px row spacing at a 1600px shorter edge.
        // Bound repetitions for extremely long text and panoramic/tiny images.
        let gridLimit = max(1, Int(sqrt(Double(max(1, 400 / strings.count)))))
        let columnSpacing = max(textWidth + shorter * 0.20,
                                max(shorter * 0.5, rotatedWidth / CGFloat(gridLimit)))
        let rowSpacing = max(shorter * 0.225, rotatedHeight / CGFloat(gridLimit))
        let firstColumn = Int(floor(-rotatedWidth / 2 / columnSpacing)) - 1
        let lastColumn = Int(ceil(rotatedWidth / 2 / columnSpacing)) + 1
        let firstRow = Int(floor(-rotatedHeight / 2 / rowSpacing)) - 1
        let lastRow = Int(ceil(rotatedHeight / 2 / rowSpacing)) + 1

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSmoothing(false)
        context.textMatrix = .identity
        context.translateBy(x: w / 2, y: h / 2)
        context.rotate(by: angle)
        for row in firstRow...lastRow {
            let stagger = row.isMultiple(of: 2) ? CGFloat(0) : columnSpacing / 2
            let baseline = CGFloat(row) * rowSpacing + blockHeight / 2 - fontSize
            for column in firstColumn...lastColumn {
                let originX = CGFloat(column) * columnSpacing + stagger
                for index in gray.indices where lengths[index] > 0 {
                    let x = originX - lengths[index] / 2
                    let y = baseline - CGFloat(index) * lineHeight
                    context.textPosition = CGPoint(x: x, y: y)
                    context.setAlpha(whiteOpacity)
                    CTLineDraw(white[index], context)
                    context.textPosition = CGPoint(x: x, y: y)
                    context.setAlpha(grayOpacity)
                    CTLineDraw(gray[index], context)
                }
            }
        }
    }

    private static func line(_ text: String, font: CTFont, stroke: CGFloat, color: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): stroke,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: color, alpha: 1),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: color, alpha: 1)
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}
