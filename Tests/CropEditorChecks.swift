// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Darwin

@main struct CropEditorCheck {
    static func require(_ value: Bool, _ message: String) {
        if !value { print("FAIL \(message)"); exit(1) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func button(_ editor: CropEditorController, _ title: String) -> NSButton {
        descendants(editor.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    private struct Raster {
        let width: Int, height: Int
        let bytes: [UInt8]
        // Drawing uses flipped view coordinates, matching the bitmap
        // readback's top-left row order.
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let px = min(width - 1, max(0, Int(x)))
            let py = min(height - 1, max(0, Int(y)))
            let offset = (py * width + px) * 4
            return Array(bytes[offset..<offset + 4])
        }
        var greenBounds: CGRect? {
            var points = [CGPoint]()
            for y in 0..<height { for x in 0..<width {
                let p = pixel(CGFloat(x), CGFloat(y))
                if p[0] < 40 && p[1] > 200 && p[2] < 40 {
                    points.append(CGPoint(x: x, y: y))
                }
            } }
            guard let first = points.first else { return nil }
            return points.dropFirst().reduce(CGRect(origin: first, size: CGSize(width: 1, height: 1))) {
                $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1)))
            }
        }
    }
    private static func raster(width: Int, height: Int, draw: (CGContext) -> Void) -> Raster {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        draw(context); context.flush()
        return Raster(width: width, height: height,
            bytes: Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4)))
    }
    private static func logo() -> CGImage {
        // Transparent left half, green top-right and yellow bottom-right make
        // vertical flips, corner errors, and unwanted opacity easy to detect.
        var bytes = [UInt8](repeating: 0, count: 40 * 20 * 4)
        for y in 0..<20 { for x in 20..<40 {
            let offset = (y * 40 + x) * 4
            bytes[offset] = y < 10 ? 0 : 255; bytes[offset + 1] = 255; bytes[offset + 3] = 255
        } }
        return CGImage(width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private static func watermarkChecks() {
        let logo = logo()
        var settings = ResizeSettings(); settings.mode = .longestEdge; settings.width = 1600
        settings.watermarkEnabled = true; settings.watermarkKind = .png; settings.watermarkImage = logo
        settings.watermarkStrength = 1; settings.watermarkSize = 0.4; settings.watermarkPadding = 0.05
        // A saved batch crop must not replace the editor's current draft.
        settings.crop = CropSelection(x: 0.65, y: 0.65, width: 0.3, height: 0.3)
        let draft = CropSelection(x: 0.2, y: 0.15, width: 0.6, height: 0.65)
        var renderChecks = 0
        for sourceSize in [CGSize(width: 400, height: 400), CGSize(width: 600, height: 400), CGSize(width: 400, height: 600)] {
            let image = CGRect(x: 20, y: 30, width: sourceSize.width, height: sourceSize.height)
            let crop = CGRect(x: image.minX + sourceSize.width * 0.2, y: image.minY + sourceSize.height * 0.15,
                              width: sourceSize.width * 0.6, height: sourceSize.height * 0.65)
            let shorter = min(crop.width, crop.height), inset = shorter * 0.05
            let w = shorter * 0.4, h = w / 2
            for corner in WatermarkCorner.allCases {
                settings.watermarkCorner = corner
                let bitmap = raster(width: Int(sourceSize.width) + 80, height: Int(sourceSize.height) + 80) { context in
                    let transform = context.ctm, clip = context.boundingBoxOfClipPath
                    try! CropWatermarkPreview.draw(settings: settings, selection: draft, sourceSize: sourceSize, imageRect: image, in: context)
                    require(context.ctm == transform && context.boundingBoxOfClipPath == clip, "Watermark leaks graphics state")
                }
                let right = corner == .upperRight || corner == .lowerRight
                let upper = corner == .upperLeft || corner == .upperRight
                let x = right ? crop.maxX - inset - w : crop.minX + inset
                let y = upper ? crop.minY + inset : crop.maxY - inset - h
                require(bitmap.pixel(x + w * 0.75, y + h * 0.25) == [0, 255, 0, 255], "PNG preview top/corner/scale mismatch")
                require(bitmap.pixel(x + w * 0.75, y + h * 0.75) == [255, 255, 0, 255], "PNG preview is upside down")
                require(bitmap.pixel(x + w * 0.25, y + h * 0.25) == [255, 255, 255, 255], "PNG preview loses transparency")
                for py in 0..<bitmap.height { for px in 0..<bitmap.width {
                    let value = bitmap.pixel(CGFloat(px), CGFloat(py))
                    if value != [255, 255, 255, 255] {
                        require(crop.contains(CGPoint(x: px, y: py)), "Watermark escapes draft crop")
                    }
                } }
                renderChecks += 1
            }
        }
        let sourceSize = CGSize(width: 2000, height: 1600), image = CGRect(x: 20, y: 30, width: 500, height: 400)
        settings.mode = .percent; settings.percent = 50; settings.watermarkKind = .text; settings.watermarkText = "SAMPLE"
        func text(_ current: ResizeSettings) -> Raster {
            raster(width: 560, height: 460) {
                try! CropWatermarkPreview.draw(settings: current, selection: draft, sourceSize: sourceSize, imageRect: image, in: $0)
            }
        }
        let marked = text(settings)
        var disabled = settings; disabled.watermarkEnabled = false
        let clean = text(disabled)
        var zero = settings; zero.watermarkStrength = 0
        require(text(zero).bytes == clean.bytes, "Zero strength shows a crop watermark")
        require(marked.bytes != clean.bytes, "Text watermark missing from crop preview")
        let crop = CGRect(x: 120, y: 90, width: 300, height: 260)
        var altered = 0
        for y in 0..<marked.height { for x in 0..<marked.width {
            if marked.pixel(CGFloat(x), CGFloat(y)) != clean.pixel(CGFloat(x), CGFloat(y)) {
                altered += 1; require(crop.contains(CGPoint(x: x, y: y)), "Text preview escapes draft crop")
            }
        } }
        require(altered > 100, "Text watermark is not visibly rendered")

        let white = NSImage(size: CGSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let selection = CropSelection(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        settings.mode = .originalDimensions; settings.watermarkKind = .png; settings.watermarkCorner = .upperLeft
        let editor = CropEditorController(itemName: "Watermark", image: white, sourceSize: CGSize(width: 4000, height: 3000),
            selection: selection, aspect: .free, watermarkSettings: settings) { _, _ in
                require(false, "Watermark updates commit crop changes")
            }
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        let canvas = descendants(editor.window!.contentView!).first { String(describing: type(of: $0)) == "CropCanvas" }!
        func capture() -> Raster {
            raster(width: Int(canvas.bounds.width.rounded(.up)), height: Int(canvas.bounds.height.rounded(.up))) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                canvas.draw(canvas.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let initial = capture(), upper = initial.greenBounds
        require(upper != nil, "Controller initializer does not display watermark")
        var off = settings; off.watermarkEnabled = false
        canvas.needsDisplay = false; editor.updateWatermark(off)
        require(canvas.needsDisplay && capture().greenBounds == nil, "Settings refresh does not remove watermark")
        require(editor.selection == selection && !editor.hasChanges && !editor.undoManager!.canUndo, "Watermark refresh changes crop/history")
        settings.watermarkCorner = .lowerRight; editor.updateWatermark(settings)
        let lowerImage = capture(), lower = lowerImage.greenBounds!
        require(lower.minX > upper!.minX && lower.minY > upper!.minY, "Live corner setting does not move canvas watermark")
        button(editor, "Reset").performClick(nil)
        let resetImage = capture(), reset = resetImage.greenBounds!
        require(reset.maxX > lower.maxX && reset.maxY > lower.maxY, "Reset does not re-anchor watermark to full image")
        editor.undo(nil)
        require(editor.selection == selection && capture().bytes == lowerImage.bytes, "Undo fails to restore draft watermark placement")
        editor.redo(nil)
        require(editor.selection == nil && capture().bytes == resetImage.bytes, "Redo fails to restore reset watermark placement")
        editor.close()
        print("PASS \(renderChecks) PNG crop-preview corner/shape renders, text/zero strength, native settings refresh, reset, undo and redo")
    }
    static func main() {
        _ = NSApplication.shared
        watermarkChecks()
        var checks = 0
        let sizes = [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000), CGSize(width: 8000, height: 1000)]
        for size in sizes {
            for aspect in CropAspect.allCases {
                let box = CGRect(x: 0.13, y: 0.17, width: 0.72, height: 0.63)
                let fitted = CropEditorGeometry.inscribed(box, aspect: aspect, sourceSize: size)
                require(fitted.minX >= box.minX - 1e-12 && fitted.maxX <= box.maxX + 1e-12, "Preset exceeds horizontal bounds")
                require(fitted.minY >= box.minY - 1e-12 && fitted.maxY <= box.maxY + 1e-12, "Preset exceeds vertical bounds")
                require(abs(fitted.midX - box.midX) < 1e-12 && abs(fitted.midY - box.midY) < 1e-12, "Preset moves center")
                if let ratio = aspect.ratio {
                    require(abs(Double(fitted.width * size.width / (fitted.height * size.height)) - ratio) < 1e-10, "Incorrect pixel aspect")
                }
                for point in [CGPoint(x: -0.1, y: -0.1), CGPoint(x: 1.1, y: -0.1), CGPoint(x: -0.1, y: 1.1), CGPoint(x: 1.1, y: 1.1)] {
                    let rect = CropEditorGeometry.anchored(CGPoint(x: 0.3, y: 0.7), point: point,
                        ratio: CropEditorGeometry.normalizedRatio(aspect, sourceSize: size))
                    require(rect.minX >= -1e-12 && rect.minY >= -1e-12 && rect.maxX <= 1 + 1e-12 && rect.maxY <= 1 + 1e-12, "Drag exceeds image")
                    if let ratio = aspect.ratio {
                        require(abs(Double(rect.width * size.width / (rect.height * size.height)) - ratio) < 1e-10, "Drag loses fixed aspect")
                    }
                    checks += 1
                }
                let original = CropSelection(x: 0.13, y: 0.17, width: 0.72, height: 0.63, aspect: aspect)
                var committed: CropSelection? = nil
                let editor = CropEditorController(itemName: "Test", image: NSImage(size: size), sourceSize: size,
                    selection: original, aspect: aspect) { crop, _ in committed = crop }
                require(editor.selection == original && !editor.hasChanges, "Opening editor rewrites crop")
                button(editor, "Apply to Batch").performClick(nil)
                require(committed == original, "Unedited apply rewrites crop")
                checks += 1
            }
        }
        let crop = CropSelection(x: 0.1, y: 0.2, width: 0.5, height: 0.6, aspect: .square)
        let editor = CropEditorController(itemName: "Undo", image: NSImage(size: sizes[0]), sourceSize: sizes[0],
            selection: crop, aspect: .square) { _, _ in }
        require(editor.window!.undoManager === editor.undoManager, "Window does not use local crop history")
        button(editor, "Reset").performClick(nil)
        require(editor.selection == nil && editor.aspect == .free && editor.hasChanges, "Reset did not clear crop")
        require(editor.undoManager!.canUndo, "Reset not undoable")
        editor.undo(nil)
        require(editor.selection == crop && editor.aspect == .square && !editor.hasChanges, "Undo did not restore original")
        require(button(editor, "Redo").isEnabled, "Redo disabled after direct undo")
        editor.redo(nil)
        require(editor.selection == nil && editor.aspect == .free, "Redo did not restore reset")
        editor.close()
        let gesture = CropEditorController(itemName: "Gesture", image: NSImage(size: sizes[0]), sourceSize: sizes[0],
            selection: nil, aspect: .free) { _, _ in }
        gesture.window!.contentView!.layoutSubtreeIfNeeded()
        let canvas = descendants(gesture.window!.contentView!).first { String(describing: type(of: $0)) == "CropCanvas" }!
        let inset = canvas.bounds.insetBy(dx: 20, dy: 20)
        let scale = min(inset.width / sizes[0].width, inset.height / sizes[0].height)
        let fitted = CGRect(x: inset.midX - sizes[0].width * scale / 2,
            y: inset.midY - sizes[0].height * scale / 2, width: sizes[0].width * scale, height: sizes[0].height * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            canvas.convert(CGPoint(x: fitted.minX + fitted.width * x, y: fitted.minY + fitted.height * y), to: nil)
        }
        func drag(_ from: CGPoint, _ to: CGPoint) {
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                    windowNumber: gesture.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: event(.leftMouseDown, from))
            canvas.mouseDragged(with: event(.leftMouseDragged, to))
            canvas.mouseUp(with: event(.leftMouseUp, to))
        }
        drag(point(0.2, 0.3), point(0.75, 0.8))
        let drawn = gesture.selection!
        require(abs(drawn.x - 0.2) < 1e-8 && abs(drawn.y - 0.3) < 1e-8,
            "Drawing uses wrong source origin")
        require(abs(drawn.width - 0.55) < 1e-8 && abs(drawn.height - 0.5) < 1e-8,
            "Drawing uses wrong source dimensions")
        gesture.undoManager!.undo(); require(gesture.selection == nil, "Completed drag not undoable")
        gesture.undoManager!.redo(); require(gesture.selection == drawn, "Drag redo mismatch")
        let picker = descendants(gesture.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        picker.selectItem(at: CropAspect.allCases.firstIndex(of: .portrait9x16)!)
        _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        require(gesture.aspect == .portrait9x16, "Preset picker did not change aspect")
        let before = gesture.selection!
        let pixel = try! before.pixelRect(width: 4000, height: 3000)
        drag(point(pixel.maxX / 4000, pixel.midY / 3000), point(0.9, pixel.midY / 3000))
        let resized = gesture.selection!
        require(abs(resized.width * 4000 / (resized.height * 3000) - 9.0 / 16) < 1e-8,
            "Fixed-ratio edge drag changed aspect")
        require(resized.x >= 0 && resized.y >= 0 && resized.x + resized.width <= 1 + 1e-8,
            "Edge drag exceeds image bounds")
        gesture.close()
        var applied = 0, closed = 0
        let cancel = CropEditorController(itemName: "Cancel", image: NSImage(size: sizes[0]), sourceSize: sizes[0],
            selection: crop, aspect: .square) { _, _ in applied += 1 }
        cancel.onClose = { closed += 1 }
        button(cancel, "Reset").performClick(nil)
        button(cancel, "Cancel").performClick(nil)
        require(applied == 0 && closed == 1, "Cancel commits draft or fails close notification")
        print("PASS \(checks) geometry/unchanged-apply groups plus native drag, edge resize, reset, undo, redo, cancel")
    }
}
