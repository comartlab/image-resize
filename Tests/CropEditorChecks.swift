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
    static func main() {
        _ = NSApplication.shared
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
