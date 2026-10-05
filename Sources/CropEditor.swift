// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Crop coordinates are normalized against the oriented source, with a top-left
/// origin. Keep drag calculations independent of the preview bitmap's size.
enum CropEditorGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func rect(_ selection: CropSelection) -> CGRect {
        CGRect(x: selection.x, y: selection.y, width: selection.width, height: selection.height)
    }

    static func bounded(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let result = rect.standardized.intersection(unit)
        return !result.isNull && result.width > 0 && result.height > 0 ? result : nil
    }

    static func selection(_ rect: CGRect, aspect: CropAspect) -> CropSelection? {
        guard let rect = bounded(rect) else { return nil }
        return CropSelection(x: Double(rect.minX), y: Double(rect.minY),
                             width: Double(rect.width), height: Double(rect.height), aspect: aspect)
    }

    static func normalizedRatio(_ aspect: CropAspect, sourceSize: CGSize) -> CGFloat? {
        guard let ratio = aspect.ratio, ratio.isFinite, ratio > 0,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        return CGFloat(ratio) * sourceSize.height / sourceSize.width
    }

    static func inscribed(_ rect: CGRect, aspect: CropAspect, sourceSize: CGSize) -> CGRect {
        let rect = bounded(rect) ?? unit
        guard let ratio = normalizedRatio(aspect, sourceSize: sourceSize) else { return rect }
        var width = rect.width, height = rect.height
        if width > height * ratio { width = height * ratio }
        else { height = width / ratio }
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    static func moved(_ rect: CGRect, delta: CGPoint) -> CGRect {
        let rect = bounded(rect) ?? unit
        return CGRect(x: min(max(0, rect.minX + delta.x), 1 - rect.width),
                      y: min(max(0, rect.minY + delta.y), 1 - rect.height),
                      width: rect.width, height: rect.height)
    }

    /// Draw and corner resize share an opposite-corner anchor. Fixed presets
    /// preserve their pixel aspect even when the pointer reaches the image edge.
    static func anchored(_ anchor: CGPoint, point: CGPoint, ratio: CGFloat?) -> CGRect {
        let anchor = clamped(anchor), point = clamped(point)
        let right = point.x >= anchor.x, down = point.y >= anchor.y
        var width = abs(point.x - anchor.x), height = abs(point.y - anchor.y)
        if let ratio = ratio {
            width = max(width, height * ratio)
            height = width / ratio
            if width > 0 && height > 0 {
                let availableWidth = right ? 1 - anchor.x : anchor.x
                let availableHeight = down ? 1 - anchor.y : anchor.y
                let scale = min(1, min(availableWidth / width, availableHeight / height))
                width *= scale; height *= scale
            }
        }
        return CGRect(x: right ? anchor.x : anchor.x - width,
                      y: down ? anchor.y : anchor.y - height, width: width, height: height)
    }

    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    func resized(_ rect: CGRect, point: CGPoint, ratio: CGFloat?) -> CGRect {
        let point = CropEditorGeometry.clamped(point)
        switch self {
        case .topLeft:
            return CropEditorGeometry.anchored(CGPoint(x: rect.maxX, y: rect.maxY), point: point, ratio: ratio)
        case .topRight:
            return CropEditorGeometry.anchored(CGPoint(x: rect.minX, y: rect.maxY), point: point, ratio: ratio)
        case .bottomLeft:
            return CropEditorGeometry.anchored(CGPoint(x: rect.maxX, y: rect.minY), point: point, ratio: ratio)
        case .bottomRight:
            return CropEditorGeometry.anchored(CGPoint(x: rect.minX, y: rect.minY), point: point, ratio: ratio)
        case .left, .right:
            let isLeft = self == .left
            let anchor = isLeft ? rect.maxX : rect.minX
            var width = max(0, isLeft ? anchor - point.x : point.x - anchor)
            width = min(width, isLeft ? anchor : 1 - anchor)
            guard let ratio = ratio else {
                return CGRect(x: isLeft ? anchor - width : anchor, y: rect.minY,
                              width: width, height: rect.height)
            }
            width = min(width, 2 * min(rect.midY, 1 - rect.midY) * ratio)
            let height = width / ratio
            return CGRect(x: isLeft ? anchor - width : anchor, y: rect.midY - height / 2,
                          width: width, height: height)
        case .top, .bottom:
            let isTop = self == .top
            let anchor = isTop ? rect.maxY : rect.minY
            var height = max(0, isTop ? anchor - point.y : point.y - anchor)
            height = min(height, isTop ? anchor : 1 - anchor)
            guard let ratio = ratio else {
                return CGRect(x: rect.minX, y: isTop ? anchor - height : anchor,
                              width: rect.width, height: height)
            }
            height = min(height, 2 * min(rect.midX, 1 - rect.midX) / ratio)
            let width = height * ratio
            return CGRect(x: rect.midX - width / 2, y: isTop ? anchor - height : anchor,
                          width: width, height: height)
        }
    }
}

private final class CropCanvas: NSView, NSUserInterfaceValidations {
    private enum DragKind {
        case draw, move, resize(CropHandle)
    }
    private struct Drag {
        let kind: DragKind
        let start: CGPoint
        let original: CropSelection?
        let rect: CGRect
    }

    let image: NSImage
    let sourceSize: CGSize
    var selection: CropSelection? { didSet { needsDisplay = true; updateAccessibility() } }
    var aspect: CropAspect
    var onCommit: ((CropSelection?, String) -> Void)?
    var onUndo: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var drag: Drag?
    private var tracking: NSTrackingArea?

    private let checkerboard: NSColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(calibratedWhite: 0.22, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 8, height: 8).fill()
            CGRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    init(image: NSImage, sourceSize: CGSize, selection: CropSelection?, aspect: CropAspect) {
        self.image = image; self.sourceSize = sourceSize; self.selection = selection; self.aspect = aspect
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Image preview and crop tool")
        setAccessibilityHelp("Drag to draw a crop. Drag inside to move it or drag a handle to resize it.")
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        let available = bounds.insetBy(dx: 20, dy: 20)
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / sourceSize.width, available.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var displayedSelection: CGRect? {
        guard let selection = selection else { return nil }
        // A completed selection displays the same whole-pixel bounds that the
        // engine exports. During a drag, retain floating coordinates for motion.
        if drag == nil,
           let pixels = try? selection.pixelRect(width: Int(sourceSize.width.rounded()),
                                                height: Int(sourceSize.height.rounded())) {
            return CGRect(x: pixels.minX / sourceSize.width, y: pixels.minY / sourceSize.height,
                          width: pixels.width / sourceSize.width, height: pixels.height / sourceSize.height)
        }
        return CropEditorGeometry.bounded(CropEditorGeometry.rect(selection))
    }

    var cropRect: CGRect? { displayedSelection }

    private func viewRect(_ normalized: CGRect) -> CGRect {
        let image = imageRect
        return CGRect(x: image.minX + normalized.minX * image.width,
                      y: image.minY + normalized.minY * image.height,
                      width: normalized.width * image.width, height: normalized.height * image.height)
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint {
        let image = imageRect
        guard image.width > 0, image.height > 0 else { return .zero }
        return CropEditorGeometry.clamped(CGPoint(x: (point.x - image.minX) / image.width,
                                                 y: (point.y - image.minY) / image.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        let imageRect = self.imageRect
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        checkerboard.setFill(); imageRect.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        guard let normalized = displayedSelection else { return }
        let crop = viewRect(normalized)
        let shade = NSBezierPath(rect: imageRect)
        shade.appendRect(crop); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.56).setFill(); shade.fill()

        let grid = NSBezierPath()
        for third in [CGFloat(1) / 3, CGFloat(2) / 3] {
            grid.move(to: CGPoint(x: crop.minX + crop.width * third, y: crop.minY))
            grid.line(to: CGPoint(x: crop.minX + crop.width * third, y: crop.maxY))
            grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * third))
            grid.line(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * third))
        }
        NSColor.white.withAlphaComponent(0.48).setStroke(); grid.lineWidth = 0.7; grid.stroke()
        let border = NSBezierPath(rect: crop)
        NSColor.black.withAlphaComponent(0.65).setStroke(); border.lineWidth = 3; border.stroke()
        NSColor.white.setStroke(); border.lineWidth = 1.3; border.stroke()
        for handle in CropHandle.allCases {
            let point = handle.point(in: crop)
            let box = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 1, yRadius: 1)
            NSColor.white.setFill(); box.fill()
            NSColor.black.withAlphaComponent(0.75).setStroke(); box.lineWidth = 0.7; box.stroke()
        }
    }

    private func handle(at point: CGPoint, rect: CGRect) -> CropHandle? {
        // Test corners before edge centers where a very small crop overlaps.
        let order: [CropHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        return order.first { handle in
            let center = handle.point(in: rect)
            return abs(center.x - point.x) <= 10 && abs(center.y - point.y) <= 10
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.insetBy(dx: -10, dy: -10).contains(point) else { return }
        window?.makeFirstResponder(self)
        let start = normalizedPoint(point)
        if let rect = displayedSelection {
            let view = viewRect(rect)
            if let handle = handle(at: point, rect: view) {
                drag = Drag(kind: .resize(handle), start: start, original: selection, rect: rect)
                handle.cursor.set()
                return
            }
            if view.contains(point) {
                drag = Drag(kind: .move, start: start, original: selection, rect: rect)
                NSCursor.closedHand.set()
                return
            }
        }
        guard imageRect.contains(point) else { return }
        drag = Drag(kind: .draw, start: start, original: selection, rect: .zero)
        NSCursor.crosshair.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = drag else { return }
        let point = normalizedPoint(convert(event.locationInWindow, from: nil))
        let ratio = CropEditorGeometry.normalizedRatio(aspect, sourceSize: sourceSize)
        let rect: CGRect
        switch drag.kind {
        case .draw: rect = CropEditorGeometry.anchored(drag.start, point: point, ratio: ratio)
        case .move:
            rect = CropEditorGeometry.moved(drag.rect, delta: CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y))
        case .resize(let handle): rect = handle.resized(drag.rect, point: point, ratio: ratio)
        }
        selection = CropEditorGeometry.selection(rect, aspect: aspect)
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction = drag else { return }
        let valid: Bool
        if let selection = selection {
            let rect = viewRect(CropEditorGeometry.rect(selection))
            valid = rect.width >= 3 && rect.height >= 3
        } else { valid = false }
        let completed = valid ? selection : interaction.original
        drag = nil; selection = completed
        window?.invalidateCursorRects(for: self)
        if completed != interaction.original {
            let name: String
            switch interaction.kind {
            case .draw: name = "Draw Crop"
            case .move: name = "Move Crop"
            case .resize: name = "Resize Crop"
            }
            onCommit?(completed, name)
        }
    }

    func finishInteraction() {
        if let drag = drag { selection = drag.original }
        drag = nil; needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
        guard let normalized = displayedSelection else { return }
        let crop = viewRect(normalized)
        addCursorRect(crop, cursor: .openHand)
        for handle in CropHandle.allCases {
            let point = handle.point(in: crop)
            addCursorRect(CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), cursor: handle.cursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let normalized = displayedSelection {
            let crop = viewRect(normalized)
            if let handle = handle(at: point, rect: crop) { handle.cursor.set(); return }
            if crop.contains(point) { NSCursor.openHand.set(); return }
        }
        (imageRect.contains(point) ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo?(event.modifierFlags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo?(event.modifierFlags.contains(.shift)); return
        }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { onUndo?(false) }
    @objc func redo(_ sender: Any?) { onUndo?(true) }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return window?.undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return window?.undoManager?.canRedo == true }
        return true
    }

    private func updateAccessibility() {
        guard let selection = selection else { setAccessibilityValue("No crop"); return }
        if let rect = try? selection.pixelRect(width: Int(sourceSize.width.rounded()), height: Int(sourceSize.height.rounded())) {
            setAccessibilityValue("\(Int(rect.width)) by \(Int(rect.height)) pixels, \(aspect.title)")
        }
    }
}

/// Owns a draft crop and local history. Applying commits the draft through the
/// callback; closing or cancelling leaves the application's saved crop intact.
final class CropEditorController: NSWindowController, NSWindowDelegate {
    private struct State: Equatable {
        let selection: CropSelection?
        let aspect: CropAspect
    }

    private(set) var selection: CropSelection?
    private(set) var aspect: CropAspect
    var onClose: (() -> Void)?
    var hasChanges: Bool { state != initialState }
    private let initialState: State
    private let onApply: (CropSelection?, CropAspect) -> Void
    private let history = UndoManager()
    private let canvas: CropCanvas
    private let aspectPicker = NSPopUpButton()
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private var state: State { State(selection: selection, aspect: aspect) }
    override var undoManager: UndoManager? { history }

    init(itemName: String, image: NSImage, sourceSize: CGSize, selection: CropSelection?, aspect: CropAspect,
         onApply: @escaping (CropSelection?, CropAspect) -> Void) {
        let safeSize = CGSize(width: sourceSize.width.isFinite && sourceSize.width > 0 ? sourceSize.width : 1,
                              height: sourceSize.height.isFinite && sourceSize.height > 0 ? sourceSize.height : 1)
        // A saved normalized box also applies to images of other proportions.
        // Opening the editor must not inscribe and replace that shared box;
        // only a gesture or an explicit preset change creates new coordinates.
        self.selection = selection; self.aspect = aspect; self.onApply = onApply
        self.initialState = State(selection: selection, aspect: aspect)
        self.canvas = CropCanvas(image: image, sourceSize: safeSize, selection: selection, aspect: aspect)
        // This is an editor window, so it remains visible when the application
        // temporarily loses focus and can become the main window when reopened.
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 690),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Preview & Crop · \(itemName)"; panel.minSize = NSSize(width: 470, height: 350)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        history.levelsOfUndo = 100
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)),
                                               name: .NSUndoManagerDidUndoChange, object: history)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)),
                                               name: .NSUndoManagerDidRedoChange, object: history)
        buildInterface(in: panel)
        canvas.onCommit = { [weak self] selection, name in
            guard let self = self else { return }
            self.change(to: State(selection: selection, aspect: self.aspect), action: name)
        }
        canvas.onUndo = { [weak self] redo in self?.performUndo(redo: redo) }
        canvas.onCancel = { [weak self] in self?.close() }
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }
    func windowWillClose(_ notification: Notification) {
        let handler = onClose; onClose = nil; handler?()
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }
        aspectPicker.addItems(withTitles: CropAspect.allCases.map(\.title))
        aspectPicker.target = self; aspectPicker.action = #selector(aspectChanged(_:))
        aspectPicker.setAccessibilityLabel("Crop aspect ratio")
        aspectPicker.widthAnchor.constraint(equalToConstant: 150).isActive = true
        configure(undoButton, #selector(undoCrop(_:)))
        configure(redoButton, #selector(redoCrop(_:)))
        configure(resetButton, #selector(resetCrop(_:)))
        undoButton.toolTip = "Undo crop change (⌘Z)"; redoButton.toolTip = "Redo crop change (⇧⌘Z)"
        resetButton.toolTip = "Remove the crop."
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [NSTextField(labelWithString: "Aspect"), aspectPicker, spacer, undoButton, redoButton, resetButton])
        toolbar.orientation = .horizontal; toolbar.alignment = .centerY; toolbar.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop(_:)))
        let apply = NSButton(title: "Apply to Batch", target: self, action: #selector(applyCrop(_:)))
        [cancel, apply].forEach { $0.bezelStyle = .rounded }
        cancel.keyEquivalent = "\u{1b}"; apply.keyEquivalent = "\r"
        apply.toolTip = "Apply this crop to every image in the batch."
        let footer = NSStackView(views: [cancel, apply])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        [toolbar, canvas, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func configure(_ button: NSButton, _ action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
    }

    private func change(to next: State, action: String) {
        canvas.finishInteraction()
        let previous = state
        guard previous != next else { canvas.selection = selection; updateControls(); return }
        let group = !history.isUndoing && !history.isRedoing
        if group { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { editor in editor.change(to: previous, action: action) }
        history.setActionName(action)
        if group { history.endUndoGrouping() }
        selection = next.selection; aspect = next.aspect
        canvas.aspect = aspect; canvas.selection = selection
        window?.invalidateCursorRects(for: canvas)
        updateControls()
    }

    private func updateControls() {
        if let index = CropAspect.allCases.firstIndex(of: aspect) { aspectPicker.selectItem(at: index) }
        undoButton.isEnabled = history.canUndo; redoButton.isEnabled = history.canRedo
        resetButton.isEnabled = selection != nil || aspect != .free
    }

    private func performUndo(redo: Bool) {
        canvas.finishInteraction()
        if redo { if history.canRedo { history.redo() } }
        else { if history.canUndo { history.undo() } }
        updateControls()
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        guard CropAspect.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let aspect = CropAspect.allCases[sender.indexOfSelectedItem]
        let selection: CropSelection?
        if self.selection == nil && aspect == .free { selection = nil }
        else {
            let current = canvas.cropRect ?? self.selection.map(CropEditorGeometry.rect) ?? CropEditorGeometry.unit
            selection = CropEditorGeometry.selection(
                CropEditorGeometry.inscribed(current, aspect: aspect, sourceSize: canvas.sourceSize), aspect: aspect)
        }
        change(to: State(selection: selection, aspect: aspect), action: "Change Aspect")
    }
    @objc private func undoCrop(_ sender: Any?) { performUndo(redo: false) }
    @objc private func redoCrop(_ sender: Any?) { performUndo(redo: true) }
    // Keep Edit-menu commands local when a toolbar control, rather than the
    // canvas, has first-responder focus.
    @objc func undo(_ sender: Any?) { performUndo(redo: false) }
    @objc func redo(_ sender: Any?) { performUndo(redo: true) }
    @objc private func historyChanged(_ notification: Notification) { updateControls() }
    @objc private func resetCrop(_ sender: Any?) { change(to: State(selection: nil, aspect: .free), action: "Reset Crop") }
    @objc private func cancelCrop(_ sender: Any?) { close() }
    @objc private func applyCrop(_ sender: Any?) {
        canvas.finishInteraction(); onApply(selection, aspect); close()
    }
}
