// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class CancellationToken {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

private final class DropArea: NSView {
    var accept: (([URL]) -> Void)?
    var enabled = true
    private var highlighted = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled, sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        highlighted = true; updateColors(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false; updateColors() }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false; updateColors() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false; updateColors()
        guard enabled, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        accept?(urls); return true
    }
}

private final class ImageTable: NSTableView {
    var removeSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { removeSelection?() }
        else { super.keyDown(with: event) }
    }
}

private final class ImageCell: NSTableCellView {
    let thumbnail = NSImageView()
    let filename = NSTextField(labelWithString: "")
    let details = NSTextField(labelWithString: "")
    let result = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)
        toolTip = "Double-click to preview and crop. The crop applies to the batch."
        thumbnail.toolTip = toolTip
        filename.lineBreakMode = .byTruncatingMiddle
        filename.font = .systemFont(ofSize: 13, weight: .medium)
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        details.lineBreakMode = .byTruncatingTail
        result.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        result.textColor = .secondaryLabelColor
        result.alignment = .right
        result.lineBreakMode = .byTruncatingMiddle
        result.maximumNumberOfLines = 2
        result.usesSingleLineMode = false
        let names = NSStackView(views: [filename, details])
        names.orientation = .vertical; names.alignment = .leading; names.spacing = 4
        [thumbnail, names, result].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 44), thumbnail.heightAnchor.constraint(equalToConstant: 44),
            names.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.trailingAnchor.constraint(lessThanOrEqualTo: result.leadingAnchor, constant: -10),
            result.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), result.centerYAnchor.constraint(equalTo: centerYAnchor),
            result.widthAnchor.constraint(equalToConstant: 156)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let photoshopType = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
    private var window: NSWindow!
    private let imageQueue = ImageQueue()
    private var items: [ImageItem] { imageQueue.items }
    private var thumbnails: [UUID: NSImage] = [:]
    private var rowResults: [UUID: String] = [:]
    private var errorIDs = Set<UUID>()
    private let outputEstimates = OutputEstimateStore()
    private var estimateCursor = 0
    private var estimateWorkerActive = false
    private var estimateSuspended = false
    private var estimateDebouncing = false
    private var estimateCancellation = CancellationToken()
    private var estimateDelay: DispatchWorkItem?
    private var outputFolder: URL?
    private var log: [String] = []
    private var busy = false
    private var pendingDiscoveries = 0
    private var importing: Bool { pendingDiscoveries > 0 }
    private var discoveryGeneration = 0
    private var removedDuringDiscovery = Set<String>()
    private var discoveryCancellation = CancellationToken()
    private let discoveryQueue = DispatchQueue(label: "com.cjohnson.imageresize.discovery", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "com.cjohnson.imageresize.thumbnails", qos: .utility)
    private var thumbnailGeneration = 0
    private var thumbnailCancellation = CancellationToken()
    private var thumbnailRequests = Set<UUID>()
    private struct PendingBatch {
        let folder: URL
        let settings: ResizeSettings
        let cancellation: CancellationToken
        let start: Date
    }
    private var pendingBatch: PendingBatch?
    private var token: CancellationToken?
    private var quitAfterBatch = false
    private var lastModeIndex = 0
    private var pixelSize = "1600"
    private var percentageSize = "50"
    private var lastFormat: OutputFormat = .jpeg
    private var standardQuality = 90.0
    private var webQuality = 75.0
    private var standardMetadata = true
    private var previewPanel: NSPanel?
    private var previewSourceID: UUID?
    private var previewGeneration = 0
    private var previewPending = false
    private var previewCancellation: CancellationToken?
    private var cropSelection: CropSelection?
    private var cropAspect: CropAspect = .free
    private var cropEditor: CropEditorController?
    private var cropLoadingPanel: NSPanel?
    private var cropSourceID: UUID?
    private var cropGeneration = 0
    private var cropCancellation: CancellationToken?
    private let cropUndoManager = UndoManager()
    private let processingQueue = DispatchQueue(label: "com.cjohnson.imageresize.processing", qos: .userInitiated)
    private let table = ImageTable()
    private let drop = DropArea()
    private let placeholder = NSStackView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let cropButton = NSButton(title: "Preview & Crop…", target: nil, action: nil)
    private let resetCropButton = NSButton(title: "Reset Crop", target: nil, action: nil)
    private let recursive = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let mode = NSPopUpButton()
    private let firstValue = NSTextField(string: "1600")
    private let secondValue = NSTextField(string: "1600")
    private let times = NSTextField(labelWithString: "×")
    private let unit = NSTextField(labelWithString: "px")
    private let format = NSPopUpButton()
    private let quality = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "90%")
    private let qualityTitle = NSTextField(labelWithString: "Quality")
    private let metadata = NSButton(checkboxWithTitle: "Keep metadata", target: nil, action: nil)
    private let watermark = NSButton(checkboxWithTitle: "Watermark", target: nil, action: nil)
    private let watermarkText = NSTextField(string: "")
    private let watermarkStrength = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let strengthTitle = NSTextField(labelWithString: "Strength")
    private let strengthLabel = NSTextField(labelWithString: "25%")
    private let previewButton = NSButton()
    private let folderButton = NSButton(title: "Choose folder…", target: nil, action: nil)
    private let revealButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let detailsButton = NSButton(title: "Details…", target: nil, action: nil)
    private let startButton = NSButton(title: "Resize", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var settings: ResizeSettings {
        var result = ResizeSettings()
        result.mode = ResizeMode.allCases[max(0, mode.indexOfSelectedItem)]
        result.width = Int(firstValue.stringValue) ?? 0
        result.height = Int(secondValue.stringValue) ?? 0
        result.percent = Double(firstValue.stringValue) ?? 0
        result.format = OutputFormat.allCases[max(0, format.indexOfSelectedItem)]
        result.quality = (result.format == .web ? standardQuality : quality.doubleValue) / 100
        result.webQuality = (result.format == .web ? quality.doubleValue : webQuality) / 100
        result.preserveMetadata = metadata.state == .on
        result.watermarkEnabled = watermark.state == .on
        result.watermarkText = watermarkText.stringValue
        result.watermarkStrength = watermarkStrength.doubleValue / 100
        result.crop = cropSelection
        return result
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenus()
        createWindow()
        restorePreferences()
        updateOptions(); updateState()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Image Resize", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Image Resize", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Image Resize", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); fileItem.title = "File"; menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Add Images or Folders…", action: #selector(addImages(_:)), keyEquivalent: "o").target = self
        let chooseOutput = fileMenu.addItem(withTitle: "Choose Output Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "o")
        chooseOutput.keyEquivalentModifierMask = [.command, .shift]; chooseOutput.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Clear", action: #selector(clear(_:)), keyEquivalent: "").target = self
        let editItem = NSMenuItem(); editItem.title = "Edit"; menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); windowItem.title = "Window"; menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu; NSApp.mainMenu = menu
    }

    @objc private func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.paragraphSpacing = 5
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(string: "")
        func append(_ text: String, link: URL? = nil) {
            var attributes = style
            if let link = link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        append("comartlab.com", link: URL(string: "https://comartlab.com"))
        append("\n\nGNU GPL v3 or later\nRedistribution permitted. Distributed modifications must remain open source under the GPL.\nProvided without warranty.\n\n")
        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
            append("View License", link: license)
        }
        append("   •   ")
        append("Source on GitHub", link: URL(string: "https://github.com/comartlab/image-resize"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func button(_ button: NSButton, action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let view = NSStackView(views: views); view.orientation = .horizontal; view.alignment = .centerY; view.spacing = spacing
        return view
    }
    private func flexible() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view
    }
    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 630), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Image Resize"; window.minSize = NSSize(width: 690, height: 540); window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        let content = window.contentView!
        button(addButton, action: #selector(addImages(_:))); button(clearButton, action: #selector(clear(_:)))
        button(cropButton, action: #selector(showCropEditor(_:)))
        button(resetCropButton, action: #selector(resetCrop(_:)))
        cropButton.toolTip = "Preview the selected image and set a crop for the batch."
        recursive.state = .on
        recursive.target = self; recursive.action = #selector(optionsChanged(_:))
        let inputRow = row([addButton, clearButton, cropButton, resetCropButton, flexible(), recursive])
        table.addTableColumn(NSTableColumn(identifier: .init("image")))
        table.headerView = nil; table.rowHeight = 62; table.intercellSpacing = .zero
        table.style = .plain; table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self; table.backgroundColor = .controlBackgroundColor
        table.setAccessibilityLabel("Images to resize")
        table.removeSelection = { [weak self] in self?.removeSelected() }
        table.target = self; table.doubleAction = #selector(showCropEditor(_:))
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Remove", action: #selector(removeRows(_:)), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Preview & Crop…", action: #selector(cropClickedRow(_:)), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Show in Finder", action: #selector(revealSource(_:)), keyEquivalent: "").target = self
        table.menu = contextMenu
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; drop.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: drop.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: drop.trailingAnchor, constant: -1), scroll.topAnchor.constraint(equalTo: drop.topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: drop.bottomAnchor, constant: -8)])
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor; icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true; icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let emptyText = NSTextField(labelWithString: "Drop images or folders")
        emptyText.textColor = .secondaryLabelColor
        placeholder.orientation = .vertical; placeholder.alignment = .centerX; placeholder.spacing = 10
        placeholder.addArrangedSubview(icon); placeholder.addArrangedSubview(emptyText)
        placeholder.translatesAutoresizingMaskIntoConstraints = false; drop.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: drop.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: drop.centerYAnchor)])
        drop.accept = { [weak self] urls in self?.importURLs(urls) }
        mode.addItems(withTitles: ["Longest edge", "Fit within", "Width", "Height", "Percent", "Keep original dimensions"])
        mode.target = self; mode.action = #selector(optionsChanged(_:)); mode.setAccessibilityLabel("Resize by")
        mode.widthAnchor.constraint(equalToConstant: 220).isActive = true
        [firstValue, secondValue].forEach {
            $0.delegate = self; $0.alignment = .right; $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            $0.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }
        firstValue.setAccessibilityLabel("Target size"); secondValue.setAccessibilityLabel("Maximum height")
        let sizeRow = row([mode, firstValue, times, secondValue, unit, flexible()])
        format.addItems(withTitles: ["Original format", "JPEG", "PNG", "TIFF", "HEIC", "Optimized for web"])
        format.selectItem(at: OutputFormat.allCases.firstIndex(of: ResizeSettings().format) ?? 1)
        format.target = self; format.action = #selector(optionsChanged(_:)); format.setAccessibilityLabel("Output format")
        format.widthAnchor.constraint(equalToConstant: 178).isActive = true
        quality.target = self; quality.action = #selector(optionsChanged(_:)); quality.setAccessibilityLabel("Compression quality")
        quality.widthAnchor.constraint(equalToConstant: 95).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 35).isActive = true
        metadata.state = .on; metadata.target = self; metadata.action = #selector(optionsChanged(_:))
        metadata.toolTip = "Keep EXIF, camera, date and GPS information. Turn off to remove this information."
        let formatRow = row([NSTextField(labelWithString: "Format"), format, qualityTitle, quality, qualityLabel, flexible(), metadata])
        watermark.target = self; watermark.action = #selector(optionsChanged(_:))
        watermarkText.placeholderString = "Watermark text"
        watermarkText.delegate = self; watermarkText.setAccessibilityLabel("Watermark text")
        watermarkText.setContentHuggingPriority(.init(1), for: .horizontal)
        watermarkText.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        watermarkText.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        watermarkStrength.target = self; watermarkStrength.action = #selector(optionsChanged(_:))
        watermarkStrength.isContinuous = true
        watermarkStrength.setAccessibilityLabel("Watermark strength")
        watermarkStrength.widthAnchor.constraint(equalToConstant: 95).isActive = true
        strengthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        strengthLabel.widthAnchor.constraint(equalToConstant: 35).isActive = true
        previewButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview watermark")
        previewButton.imagePosition = .imageOnly; previewButton.bezelStyle = .rounded
        previewButton.target = self; previewButton.action = #selector(showPreview(_:)); previewButton.toolTip = "Preview the watermark. Choose Crop in the preview to crop the batch."
        let watermarkRow = row([watermark, watermarkText, strengthTitle, watermarkStrength, strengthLabel, previewButton])
        button(folderButton, action: #selector(chooseFolder(_:)))
        folderButton.alignment = .left; folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.setContentHuggingPriority(.init(1), for: .horizontal)
        folderButton.setAccessibilityLabel("Output folder")
        revealButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Show output folder in Finder")
        revealButton.imagePosition = .imageOnly; revealButton.bezelStyle = .rounded
        revealButton.target = self; revealButton.action = #selector(revealOutput(_:)); revealButton.toolTip = "Show output folder in Finder"
        let outputRow = row([NSTextField(labelWithString: "Output"), folderButton, revealButton])
        button(startButton, action: #selector(startOrCancel(_:))); startButton.keyEquivalent = "\r"
        startButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        startButton.bezelColor = .controlAccentColor
        button(detailsButton, action: #selector(showDetails(_:)))
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let actionRow = row([status, flexible(), detailsButton, startButton])
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        let stack = NSStackView(views: [inputRow, drop, sizeRow, formatRow, watermarkRow, outputRow, progress, actionRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            drop.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        [inputRow, drop, sizeRow, formatRow, watermarkRow, outputRow, progress, actionRow].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        drop.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func restorePreferences() {
        let prefs = UserDefaults.standard
        if let saved = prefs.string(forKey: "mode"), let index = ResizeMode.allCases.firstIndex(where: { $0.rawValue == saved }) { mode.selectItem(at: index) }
        if let saved = prefs.string(forKey: "format"), let index = OutputFormat.allCases.firstIndex(where: { $0.rawValue == saved }) { format.selectItem(at: index) }
        firstValue.stringValue = prefs.string(forKey: "size") ?? (mode.indexOfSelectedItem == 4 ? "50" : "1600")
        secondValue.stringValue = prefs.string(forKey: "height") ?? "1600"
        lastModeIndex = mode.indexOfSelectedItem
        pixelSize = prefs.string(forKey: "pixelSize") ?? (lastModeIndex == 4 ? "1600" : firstValue.stringValue)
        percentageSize = prefs.string(forKey: "percentageSize") ?? (lastModeIndex == 4 ? firstValue.stringValue : "50")
        if prefs.object(forKey: "quality") != nil {
            let saved = prefs.double(forKey: "quality")
            if saved.isFinite { standardQuality = min(100, max(1, saved)) }
        }
        if prefs.object(forKey: "webQuality") != nil {
            let saved = prefs.double(forKey: "webQuality")
            if saved.isFinite { webQuality = min(100, max(1, saved)) }
        }
        if prefs.object(forKey: "metadata") != nil { standardMetadata = prefs.bool(forKey: "metadata") }
        lastFormat = OutputFormat.allCases[max(0, format.indexOfSelectedItem)]
        quality.doubleValue = lastFormat == .web ? webQuality : standardQuality
        metadata.state = lastFormat == .web ? .off : (standardMetadata ? .on : .off)
        if prefs.object(forKey: "recursive") != nil { recursive.state = prefs.bool(forKey: "recursive") ? .on : .off }
        watermark.state = prefs.bool(forKey: "watermarkEnabled") ? .on : .off
        watermarkText.stringValue = prefs.string(forKey: "watermarkText") ?? ""
        if prefs.object(forKey: "watermarkStrength") != nil {
            let saved = prefs.double(forKey: "watermarkStrength")
            if saved.isFinite { watermarkStrength.doubleValue = min(100, max(0, saved)) }
        }
        if let path = prefs.string(forKey: "output") { outputFolder = URL(fileURLWithPath: path, isDirectory: true) }
        if let saved = prefs.string(forKey: "cropAspect"), let aspect = CropAspect(rawValue: saved) { cropAspect = aspect }
        if let data = prefs.data(forKey: "cropSelection"), let crop = try? JSONDecoder().decode(CropSelection.self, from: data),
           (try? crop.pixelRect(width: 1000, height: 1000)) != nil { cropSelection = crop; cropAspect = crop.aspect }
        updateFolder()
    }
    private func savePreferences() {
        let prefs = UserDefaults.standard
        prefs.set(settings.mode.rawValue, forKey: "mode"); prefs.set(settings.format.rawValue, forKey: "format")
        prefs.set(firstValue.stringValue, forKey: "size"); prefs.set(secondValue.stringValue, forKey: "height")
        if mode.indexOfSelectedItem == 4 { percentageSize = firstValue.stringValue }
        else { pixelSize = firstValue.stringValue }
        prefs.set(pixelSize, forKey: "pixelSize"); prefs.set(percentageSize, forKey: "percentageSize")
        if settings.format == .web { webQuality = quality.doubleValue }
        else { standardQuality = quality.doubleValue; standardMetadata = metadata.state == .on }
        prefs.set(standardQuality, forKey: "quality"); prefs.set(webQuality, forKey: "webQuality")
        prefs.set(standardMetadata, forKey: "metadata")
        prefs.set(recursive.state == .on, forKey: "recursive"); prefs.set(outputFolder?.path, forKey: "output")
        prefs.set(watermark.state == .on, forKey: "watermarkEnabled"); prefs.set(watermarkText.stringValue, forKey: "watermarkText")
        prefs.set(watermarkStrength.doubleValue, forKey: "watermarkStrength")
        prefs.set(cropAspect.rawValue, forKey: "cropAspect")
        if let crop = cropSelection, let data = try? JSONEncoder().encode(crop) { prefs.set(data, forKey: "cropSelection") }
        else { prefs.removeObject(forKey: "cropSelection") }
    }
    @objc private func optionsChanged(_ sender: Any?) {
        if sender as? NSPopUpButton === format {
            if lastFormat == .web { webQuality = quality.doubleValue }
            else { standardQuality = quality.doubleValue; standardMetadata = metadata.state == .on }
            lastFormat = OutputFormat.allCases[max(0, format.indexOfSelectedItem)]
            quality.doubleValue = lastFormat == .web ? webQuality : standardQuality
            metadata.state = lastFormat == .web ? .off : (standardMetadata ? .on : .off)
        }
        if sender as? NSPopUpButton === mode {
            if mode.indexOfSelectedItem == 4 && lastModeIndex != 4 {
                pixelSize = firstValue.stringValue; firstValue.stringValue = percentageSize
            } else if lastModeIndex == 4 && mode.indexOfSelectedItem != 4 {
                percentageSize = firstValue.stringValue; firstValue.stringValue = pixelSize
            }
            lastModeIndex = mode.indexOfSelectedItem
        }
        let refreshPreview = sender as? NSSlider === watermarkStrength && previewPanel != nil
        if refreshPreview { cancelPreviewWork() } else { dismissPreview() }
        rowResults.removeAll(); errorIDs.removeAll(); invalidateEstimates()
        updateOptions(); updateState(); reloadImageRows(); savePreferences()
        if refreshPreview {
            let generation = previewGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self = self, self.previewGeneration == generation, self.previewPanel != nil else { return }
                self.showPreview(nil)
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        dismissPreview(); rowResults.removeAll(); errorIDs.removeAll(); invalidateEstimates()
        updateState(); reloadImageRows()
        // Save every edit, including unfinished size edits when quitting.
        savePreferences()
    }
    func controlTextDidEndEditing(_ obj: Notification) { savePreferences() }
    private func updateOptions() {
        let fit = mode.indexOfSelectedItem == 1
        let original = settings.mode == .originalDimensions
        times.isHidden = !fit; secondValue.isHidden = !fit
        firstValue.isHidden = original; unit.isHidden = original
        unit.stringValue = mode.indexOfSelectedItem == 4 ? "%" : "px"
        let web = settings.format == .web
        let compressed = web || format.indexOfSelectedItem == 0 || format.indexOfSelectedItem == 1 || format.indexOfSelectedItem == 4
        [quality, qualityLabel, qualityTitle].forEach { $0.isHidden = !compressed }
        format.toolTip = web ? "Small sRGB JPEG or PNG, chosen automatically. Transparency is preserved; source metadata is removed. Pixel dimensions follow your size and crop settings." : nil
        quality.toolTip = web ? "JPEG quality for web exports. PNG is used when smaller or needed for transparency. Remembered separately from other formats." : nil
        metadata.toolTip = web ? "Web exports remove source metadata to reduce file size. Your metadata preference is retained for other formats." : "Keep EXIF, camera, date and GPS information. Turn off to remove this information."
        qualityLabel.stringValue = "\(Int(quality.doubleValue))%"
        strengthLabel.stringValue = "\(Int(watermarkStrength.doubleValue.rounded()))%"
    }
    private func updateFolder() {
        folderButton.title = outputFolder?.path ?? "Choose folder…"
        folderButton.toolTip = outputFolder?.path; revealButton.isEnabled = outputFolder != nil
    }
    private func validationMessage() -> String? {
        let current = settings
        if current.mode == .percent {
            if !current.percent.isFinite || current.percent <= 0 || current.percent > 100 { return "Percent must be greater than 0 and at most 100." }
        } else if current.mode != .originalDimensions && (current.width < 1 || (current.mode == .fit && current.height < 1)) {
            return "Enter positive whole pixel sizes."
        }
        if current.watermarkEnabled {
            do { try TextWatermark.validate(current.watermarkText, strength: current.watermarkStrength) }
            catch { return error.localizedDescription }
        }
        return nil
    }
    private func updateState() {
        let locked = busy
        [addButton, clearButton, recursive, metadata, watermark, folderButton].forEach { $0.isEnabled = !locked }
        metadata.isEnabled = !locked && settings.format != .web
        clearButton.isEnabled = !locked && (!items.isEmpty || importing)
        cropButton.isEnabled = !locked && !items.isEmpty
        resetCropButton.isEnabled = !locked && cropSelection != nil
        [mode, format].forEach { $0.isEnabled = !locked }
        [firstValue, secondValue].forEach { $0.isEnabled = !locked }
        watermarkText.isEnabled = !locked && watermark.state == .on
        watermarkStrength.isEnabled = !locked && watermark.state == .on
        strengthTitle.textColor = watermarkStrength.isEnabled ? .labelColor : .disabledControlTextColor
        strengthLabel.textColor = strengthTitle.textColor
        updatePreviewState()
        quality.isEnabled = !locked; drop.enabled = !locked
        placeholder.isHidden = !items.isEmpty
        detailsButton.isHidden = log.isEmpty
        startButton.title = busy ? "Cancel" : (settings.mode == .originalDimensions ? "Export" : "Resize")
        startButton.isEnabled = busy || ((!items.isEmpty || importing) && outputFolder != nil && validationMessage() == nil)
        startButton.keyEquivalent = busy ? "\u{1b}" : "\r"
        if !busy {
            if let invalid = validationMessage() { status.stringValue = invalid }
            else {
                updateEstimateSummary()
            }
        }
    }
    private var previewItem: ImageItem? {
        let index = table.selectedRow >= 0 ? table.selectedRow : 0
        return items.indices.contains(index) ? items[index] : nil
    }
    private func willExport(_ item: ImageItem) -> Bool {
        guard item.isInspected, let plan = try? ResizeEngine.outputPlan(width: item.width, height: item.height, settings: settings) else { return false }
        return !plan.skipped
    }
    private func updatePreviewState() {
        let exports = previewItem.map(willExport) ?? false
        previewButton.isEnabled = !busy && !previewPending && exports && watermark.state == .on && validationMessage() == nil
        previewButton.toolTip = previewItem?.isInspected == false ? "Preview is loading in the background." : (exports ? "Preview the watermark. Choose Crop in the preview to crop the batch." : (cropSelection == nil ? "Images already at or below the selected size are skipped." : "Cropped images already at or below the selected size are skipped."))
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if previewSourceID != previewItem?.id { dismissPreview() }
        if cropSourceID != previewItem?.id { dismissCropEditor() }
        updatePreviewState()
        startNextEstimate()
    }

    private func updateEstimateSummary() {
        guard !busy else { return }
        let count = items.count
        let bytes = imageQueue.inspectedCount == count && count > 0
            ? " · \(ByteCountFormatter.string(fromByteCount: imageQueue.totalBytes, countStyle: .file))" : ""
        var text = count > 0 ? "\(count) image\(count == 1 ? "" : "s")\(bytes)" : ""
        if importing { text += (text.isEmpty ? "" : " · ") + "Adding files…" }
        if count > 0 && validationMessage() == nil {
            if outputEstimates.completedCount == 0 { text += " · Estimating output…" }
            else {
                let size = ByteCountFormatter.string(fromByteCount: outputEstimates.totalBytes, countStyle: .file)
                if outputEstimates.pendingCount > 0 {
                    text += " · Est. output: ~\(size) so far (\(outputEstimates.completedCount)/\(count))"
                } else if outputEstimates.failureCount > 0 {
                    text += " · Known output: ~\(size) · \(outputEstimates.failureCount) unavailable"
                } else { text += " · Est. output: ~\(size)" }
            }
        }
        status.stringValue = text
        status.toolTip = text + "\nOutput estimates use the current export settings. Skipped files contribute no output. Estimates update in the background; source changes can affect final sizes."
    }

    private func pauseEstimates() {
        estimateSuspended = true
        estimateCancellation.cancel(); estimateCancellation = CancellationToken()
        estimateDelay?.cancel(); estimateDelay = nil; estimateDebouncing = false
        // The cancelled item is revisited if background work resumes.
        estimateCursor = 0
    }

    private func invalidateEstimates() {
        pauseEstimates(); outputEstimates.reset(); scheduleEstimates()
    }

    private func scheduleEstimates() {
        guard !busy else { return }
        estimateSuspended = false
        estimateDelay?.cancel(); estimateDebouncing = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.estimateDebouncing = false; self.estimateDelay = nil
            self.startNextEstimate()
        }
        estimateDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func startNextEstimate() {
        guard !busy, !estimateSuspended, !estimateDebouncing, !estimateWorkerActive,
              validationMessage() == nil, outputEstimates.pendingCount > 0 else { return }
        var next: ImageItem?
        // A selected file gets priority without queuing a decode for every row.
        if table.selectedRow >= 0, table.selectedRow < items.count {
            let selected = items[table.selectedRow]
            if outputEstimates.value(for: selected.id) == nil { next = selected }
        }
        while next == nil && estimateCursor < items.count {
            let item = items[estimateCursor]; estimateCursor += 1
            if outputEstimates.value(for: item.id) == nil { next = item }
        }
        guard let item = next else { return }
        let generation = outputEstimates.generation
        let cancellation = estimateCancellation
        let current = settings
        estimateWorkerActive = true
        // Share the serial image worker so estimates and exports never hold
        // two full-resolution processing buffers concurrently. Only this one
        // trial is queued; an export cancels it at the next native-stage boundary.
        processingQueue.async(qos: .utility) { [weak self] in
            let outcome: Result<OutputSizeEstimate, Error> = autoreleasepool {
                Result {
                    try ResizeEngine.estimateOutput(item, settings: current,
                        cancelled: { cancellation.cancelled }, onInspect: { inspected in
                            DispatchQueue.main.async {
                                guard let self = self, !cancellation.cancelled,
                                      self.outputEstimates.generation == generation else { return }
                                _ = self.imageQueue.update(inspected)
                                self.reloadImageRow(item.id); self.updatePreviewState()
                            }
                        })
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.estimateWorkerActive = false
                if !cancellation.cancelled && self.outputEstimates.generation == generation {
                    let value: OutputEstimateValue
                    switch outcome {
                    case .success(let estimate): value = .ready(estimate)
                    case .failure(let error): value = .unavailable(error.localizedDescription)
                    }
                    if self.outputEstimates.record(value, for: item.id, generation: generation) {
                        self.reloadImageRow(item.id)
                        if self.rowResults.isEmpty { self.updateEstimateSummary() }
                    }
                }
                self.startNextEstimate()
            }
        }
    }
    private func reloadImageRows() {
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: IndexSet(integer: 0))
    }
    private func reloadImageRow(_ id: UUID) {
        guard let row = imageQueue.index(of: id) else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, NSLocationInRange(row, visible) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func cancelThumbnailWork() {
        thumbnailCancellation.cancel(); thumbnailCancellation = CancellationToken()
        thumbnailGeneration += 1; thumbnailRequests = Set(thumbnails.keys)
    }

    // Only visible cells request thumbnails. A large batch never creates a backlog
    // of full-image decodes, and starting an export stops remaining requests.
    private func requestThumbnail(_ item: ImageItem) {
        guard !busy, thumbnailRequests.insert(item.id).inserted else { return }
        let generation = thumbnailGeneration
        let cancellation = thumbnailCancellation
        thumbnailQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            let visible = DispatchQueue.main.sync { () -> Bool in
                guard let self = self, self.thumbnailGeneration == generation,
                      let row = self.imageQueue.index(of: item.id) else { return false }
                let range = self.table.rows(in: self.table.visibleRect)
                let visible = range.location != NSNotFound && NSLocationInRange(row, range)
                if !visible { self.thumbnailRequests.remove(item.id) }
                return visible
            }
            guard visible else { return }
            let result = autoreleasepool { ImagePreview.load(item, cancelled: { cancellation.cancelled }) }
            DispatchQueue.main.async {
                guard let self = self, !cancellation.cancelled, self.thumbnailGeneration == generation,
                      self.imageQueue.index(of: item.id) != nil else { return }
                if let inspected = result.0 { _ = self.imageQueue.update(inspected) }
                if let thumbnail = result.1 { self.thumbnails[item.id] = thumbnail }
                self.reloadImageRow(item.id); self.updatePreviewState()
            }
        }
    }

    @objc private func addImages(_ sender: Any?) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add"; panel.message = ""; panel.allowedContentTypes = [.image, .tiff, Self.photoshopType, .folder]
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK { self?.importURLs(panel.urls) } }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        importURLs(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
    private func appendFiles(_ urls: [URL], fromDiscovery: Bool = false) {
        let accepted = fromDiscovery ? urls.filter { !removedDuringDiscovery.contains($0.standardizedFileURL.path) } : urls
        let range = imageQueue.append(accepted)
        guard !range.isEmpty else { return }
        outputEstimates.append(range.map { items[$0].id })
        table.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
        updateState(); scheduleEstimates()
    }
    private func importURLs(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        log.removeAll(); rowResults.removeAll(); errorIDs.removeAll(); progress.isHidden = true
        // Common file drops enter the queue without even statting a source.
        // Folders and unfamiliar paths need only a background directory listing.
        var files: [URL] = [], discovery: [URL] = []
        for url in urls {
            if !url.hasDirectoryPath && ImageDiscovery.isImagePath(url) { files.append(url) }
            else { discovery.append(url) }
        }
        for url in urls { removedDuringDiscovery.remove(url.standardizedFileURL.path) }
        appendFiles(files)
        guard !discovery.isEmpty else { updateState(); return }
        pendingDiscoveries += 1; updateState()
        let includeSubfolders = recursive.state == .on
        let excluded = outputFolder
        let generation = discoveryGeneration
        let cancellation = discoveryCancellation
        discoveryQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            let errors = ImageDiscovery.list(discovery, recursive: includeSubfolders, excluding: excluded,
                cancelled: { cancellation.cancelled }, publish: { files in
                    DispatchQueue.main.async {
                        guard let self = self, self.discoveryGeneration == generation else { return }
                        self.appendFiles(files, fromDiscovery: true)
                    }
                })
            DispatchQueue.main.async {
                guard let self = self, self.discoveryGeneration == generation else { return }
                self.pendingDiscoveries -= 1; self.log.append(contentsOf: errors)
                if !self.importing { self.removedDuringDiscovery.removeAll() }
                self.updateState()
                if !self.importing, let request = self.pendingBatch {
                    self.pendingBatch = nil; self.runBatch(request)
                } else if !self.importing && self.items.isEmpty {
                    self.status.stringValue = errors.isEmpty ? "No supported images found" : "Could not list input files"
                }
            }
        }
    }
    @objc private func clear(_ sender: Any?) {
        guard !busy else { return }
        dismissPreview(); dismissCropEditor()
        discoveryCancellation.cancel(); discoveryCancellation = CancellationToken()
        discoveryGeneration += 1; pendingDiscoveries = 0
        removedDuringDiscovery.removeAll()
        cancelThumbnailWork(); pauseEstimates(); outputEstimates.clear()
        imageQueue.clear(); thumbnails.removeAll(); rowResults.removeAll(); errorIDs.removeAll(); log.removeAll()
        table.reloadData(); progress.isHidden = true; updateState()
    }
    private func removeSelected() {
        guard !busy else { return }
        dismissPreview(); dismissCropEditor()
        let selection = table.selectedRowIndexes
        if importing {
            for index in selection where items.indices.contains(index) { removedDuringDiscovery.insert(items[index].url.standardizedFileURL.path) }
        }
        pauseEstimates()
        let removed = imageQueue.remove(at: selection)
        outputEstimates.remove(removed)
        for id in removed {
            thumbnails.removeValue(forKey: id); thumbnailRequests.remove(id)
            rowResults.removeValue(forKey: id); errorIDs.remove(id)
        }
        rowResults.removeAll(); errorIDs.removeAll()
        table.reloadData(); updateState(); scheduleEstimates()
    }
    @objc private func removeRows(_ sender: Any?) {
        if table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        removeSelected()
    }
    @objc private func revealSource(_ sender: Any?) {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if index >= 0 && index < items.count { NSWorkspace.shared.activateFileViewerSelecting([items[index].url]) }
    }
    @objc private func chooseFolder(_ sender: Any?) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose"; panel.directoryURL = outputFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.outputFolder = panel.url; self?.updateFolder(); self?.updateState(); self?.savePreferences() }
        }
    }
    @objc private func revealOutput(_ sender: Any?) { if let url = outputFolder { NSWorkspace.shared.open(url) } }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { busy ? nil : cropUndoManager }

    private func applyCrop(_ selection: CropSelection?, aspect: CropAspect) {
        guard !busy, selection != cropSelection || aspect != cropAspect else { return }
        let previous = cropSelection, previousAspect = cropAspect
        cropUndoManager.registerUndo(withTarget: self) { owner in
            owner.dismissCropEditor(); owner.applyCrop(previous, aspect: previousAspect)
        }
        cropUndoManager.setActionName("Crop")
        cropSelection = selection; cropAspect = aspect
        dismissPreview(); rowResults.removeAll(); errorIDs.removeAll(); invalidateEstimates()
        updateState(); reloadImageRows(); savePreferences()
    }

    @objc private func resetCrop(_ sender: Any?) {
        guard !busy else { return }
        dismissCropEditor(); applyCrop(nil, aspect: .free)
    }

    @objc private func cropClickedRow(_ sender: Any?) {
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        showCropEditor(sender)
    }

    private func dismissCropEditor() {
        cropGeneration += 1; cropCancellation?.cancel(); cropCancellation = nil; cropSourceID = nil
        let loading = cropLoadingPanel; cropLoadingPanel = nil; loading?.close()
        let editor = cropEditor; cropEditor = nil; editor?.close()
    }

    @objc private func showCropEditor(_ sender: Any?) {
        guard !busy, let item = previewItem else { return }
        window.makeFirstResponder(nil)
        if cropSourceID == item.id, let editor = cropEditor { editor.show(); return }
        dismissPreview(); dismissCropEditor()
        cropSourceID = item.id
        let generation = cropGeneration
        let cancellation = CancellationToken(); cropCancellation = cancellation
        let loading = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        loading.title = item.url.lastPathComponent; loading.delegate = self; loading.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false; loading.contentView?.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: loading.contentView!.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: loading.contentView!.centerYAnchor)])
        spinner.startAnimation(nil); cropLoadingPanel = loading; loading.center(); loading.makeKeyAndOrderFront(nil)
        // Explicit full-size crop previews share the export worker so a
        // cancelled PSD decode cannot overlap another full-resolution buffer.
        processingQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            let result = autoreleasepool { Result { try ImagePreview.editorImage(item, cancelled: { cancellation.cancelled }) } }
            DispatchQueue.main.async {
                guard let self = self, self.cropGeneration == generation, !cancellation.cancelled,
                      !self.busy, self.imageQueue.index(of: item.id) != nil else { return }
                self.cropLoadingPanel = nil; loading.close(); self.cropCancellation = nil
                switch result {
                case .success(let (inspected, image)):
                    _ = self.imageQueue.update(inspected); self.reloadImageRow(item.id); self.updatePreviewState()
                    let controller = CropEditorController(itemName: item.url.lastPathComponent, image: image,
                        sourceSize: CGSize(width: inspected.width, height: inspected.height),
                        selection: self.cropSelection, aspect: self.cropAspect,
                        onApply: { [weak self] crop, aspect in self?.applyCrop(crop, aspect: aspect) })
                    controller.onClose = { [weak self, weak controller] in
                        guard let self = self, self.cropEditor === controller else { return }
                        self.cropEditor = nil; self.cropSourceID = nil
                    }
                    self.cropEditor = controller; controller.show()
                case .failure(let error):
                    self.cropSourceID = nil
                    let alert = NSAlert(); alert.messageText = "Could not open crop preview"; alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func cancelPreviewWork() {
        previewGeneration += 1; previewPending = false
        previewCancellation?.cancel(); previewCancellation = nil
        previewPanel?.contentView?.subviews.compactMap { $0 as? NSProgressIndicator }.forEach { $0.removeFromSuperview() }
    }
    private func dismissPreview() {
        cancelPreviewWork()
        previewSourceID = nil
        let panel = previewPanel; previewPanel = nil; panel?.close()
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === cropLoadingPanel {
            dismissCropEditor()
        } else if let closing = notification.object as? NSWindow, closing === previewPanel {
            previewGeneration += 1; previewPending = false
            previewCancellation?.cancel(); previewCancellation = nil
            previewPanel = nil; previewSourceID = nil; updateState()
        } else if notification.object as? NSWindow === window {
            savePreferences(); dismissCropEditor(); dismissPreview()
        }
    }
    @objc private func showPreview(_ sender: Any?) {
        window.makeFirstResponder(nil)
        guard !busy && !previewPending, !items.isEmpty, watermark.state == .on, validationMessage() == nil else { return }
        cancelPreviewWork()
        guard let item = previewItem, willExport(item) else { updatePreviewState(); return }
        previewSourceID = item.id
        guard let target = try? ResizeEngine.outputPlan(width: item.width, height: item.height, settings: settings) else { return }
        var previewSettings = settings
        let previewEdge = max(target.width, target.height)
        previewSettings.mode = settings.mode == .originalDimensions && previewEdge <= 1200 ? .originalDimensions : .longestEdge
        previewSettings.width = min(1200, previewEdge)
        previewSettings.preserveMetadata = false
        let generation = previewGeneration
        let cancellation = CancellationToken(); previewCancellation = cancellation
        previewPending = true; updateState()
        let panel: NSPanel
        let imageView: NSImageView
        if let existing = previewPanel,
           let existingImage = existing.contentView?.subviews.compactMap({ $0 as? NSImageView }).first {
            panel = existing; imageView = existingImage
            if sender != nil { panel.makeKeyAndOrderFront(nil) }
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Watermark preview · \(item.url.lastPathComponent)"
            panel.delegate = self
            panel.minSize = NSSize(width: 300, height: 300); panel.isReleasedWhenClosed = false
            imageView = NSImageView(); imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.setAccessibilityLabel("Watermarked output preview")
            panel.contentView?.addSubview(imageView)
            let editCrop = NSButton(title: "Crop…", target: self, action: #selector(showCropEditor(_:)))
            editCrop.bezelStyle = .rounded; editCrop.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(editCrop)
            NSLayoutConstraint.activate([
                editCrop.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 8),
                editCrop.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
                imageView.topAnchor.constraint(equalTo: editCrop.bottomAnchor, constant: 8),
                imageView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
            ])
            previewPanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
        }
        let loading = NSProgressIndicator(); loading.style = .spinning; loading.isIndeterminate = true
        loading.translatesAutoresizingMaskIntoConstraints = false; panel.contentView?.addSubview(loading)
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo: imageView.centerXAnchor), loading.centerYAnchor.constraint(equalTo: imageView.centerYAnchor)])
        loading.startAnimation(nil)
        processingQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            let result: Result<NSImage, Error> = autoreleasepool {
                Result {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ImageResize-preview-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let result = try ResizeEngine.resize(item, to: temporary, settings: previewSettings)
                    guard let url = result.output, let image = NSImage(data: try Data(contentsOf: url)) else { throw ResizeError.decode("the preview") }
                    return image
                }
            }
            DispatchQueue.main.async {
                guard let self = self, self.previewGeneration == generation else { return }
                self.previewPending = false; self.previewCancellation = nil; self.updateState(); loading.stopAnimation(nil); loading.removeFromSuperview()
                switch result {
                case .success(let image): imageView.image = image
                case .failure(let error):
                    self.dismissPreview()
                    let alert = NSAlert(); alert.messageText = "Could not create preview"; alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }
    @objc private func startOrCancel(_ sender: Any?) {
        if busy {
            token?.cancel()
            if pendingBatch != nil {
                pendingBatch = nil; busy = false; token = nil; updateState(); reloadImageRows()
                status.stringValue = "Stopped"; scheduleEstimates()
            } else {
                startButton.isEnabled = false; status.stringValue = "Finishing current image…"
            }
            return
        }
        window.makeFirstResponder(nil)
        guard (!items.isEmpty || importing), let folder = outputFolder, validationMessage() == nil else { return }
        dismissPreview(); dismissCropEditor(); cancelThumbnailWork(); pauseEstimates()
        let cancellation = CancellationToken()
        let request = PendingBatch(folder: folder, settings: settings, cancellation: cancellation, start: Date())
        token = cancellation; busy = true; rowResults.removeAll(); errorIDs.removeAll(); log.removeAll(); savePreferences()
        progress.doubleValue = 0; progress.isHidden = false; updateState()
        status.stringValue = "Starting…"
        if importing {
            // Complete the path snapshot before writing anything. This includes
            // the entire drop and prevents outputs joining their own input batch.
            pendingBatch = request; status.stringValue = "Adding files…"
        } else { runBatch(request) }
    }
    private func runBatch(_ request: PendingBatch) {
        let batch = items
        guard !batch.isEmpty else {
            busy = false; token = nil; progress.isHidden = true; updateState()
            status.stringValue = log.isEmpty ? "No supported images found" : "Could not list input files"
            if quitAfterBatch { NSApp.reply(toApplicationShouldTerminate: true) }
            return
        }
        let folder = request.folder, currentSettings = request.settings
        let cancellation = request.cancellation, start = request.start
        processingQueue.async { [weak self] in
            var completed = 0; var failed = 0; var outputs = 0; var skipped = 0; var originalBytes: Int64 = 0; var resultingBytes: Int64 = 0
            for item in batch {
                if cancellation.cancelled { break }
                let position = completed + 1
                DispatchQueue.main.async { self?.status.stringValue = "\(position) / \(batch.count) · \(item.url.lastPathComponent)" }
                let outcome: Result<ResizeResult, Error> = autoreleasepool {
                    Result {
                        try ResizeEngine.resize(item, to: folder, settings: currentSettings, onInspect: { inspected in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                _ = self.imageQueue.update(inspected); self.reloadImageRow(item.id)
                            }
                        })
                    }
                }
                completed += 1
                var text: String; var entry: String; var isError = false
                let actualSize: OutputEstimateValue
                switch outcome {
                case .success(let result):
                    if result.output != nil { outputs += 1; originalBytes += result.inputBytes; resultingBytes += result.outputBytes }
                    if result.skipped { skipped += 1 }
                    text = result.skipped ? "Skipped" : "\(result.width) × \(result.height) ✓\n\(ByteCountFormatter.string(fromByteCount: result.outputBytes, countStyle: .file))"
                    let destination = result.output.map { "→ \($0.path)\n" } ?? ""
                    entry = "\(item.url.path)\n\(destination)\(result.message)\n"
                    actualSize = .ready(OutputSizeEstimate(width: result.width, height: result.height,
                        outputBytes: result.outputBytes, skipped: result.skipped, formatExtension: result.output?.pathExtension))
                case .failure(let error):
                    failed += 1; isError = true; text = "Failed"
                    entry = "\(item.url.path)\n\(error.localizedDescription)\n"
                    actualSize = .unavailable(error.localizedDescription)
                }
                let count = completed
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.rowResults[item.id] = text; if isError { self.errorIDs.insert(item.id) }
                    self.outputEstimates.record(actualSize, for: item.id, generation: self.outputEstimates.generation)
                    self.log.append(entry); self.progress.doubleValue = Double(count) / Double(batch.count)
                    self.reloadImageRow(item.id)
                }
            }
            let duration = Date().timeIntervalSince(start)
            let cancelled = cancellation.cancelled
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false; self.token = nil; self.updateState(); self.reloadImageRows()
                let bytes = ByteCountFormatter.string(fromByteCount: resultingBytes, countStyle: .file)
                let saved = originalBytes > resultingBytes ? " · saved \(ByteCountFormatter.string(fromByteCount: originalBytes - resultingBytes, countStyle: .file))" : ""
                self.status.stringValue = "\(cancelled ? "Stopped" : "Done") · \(outputs) saved\(skipped > 0 ? " · \(skipped) skipped" : "")\(failed > 0 ? " · \(failed) failed" : "") · \(bytes)\(saved)"
                self.status.toolTip = String(format: "%.1f seconds", duration)
                if self.quitAfterBatch { NSApp.reply(toApplicationShouldTerminate: true) }
                else if self.outputEstimates.pendingCount > 0 { self.scheduleEstimates() }
            }
        }
    }
    @objc private func showDetails(_ sender: Any?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Batch details"
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 14); text.string = log.joined(separator: "\n")
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; scroll.documentView = text; panel.contentView?.addSubview(scroll)
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let plan = item.isInspected ? try? ResizeEngine.outputPlan(width: item.width, height: item.height, settings: settings) : nil
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: self) as? ImageCell) ?? ImageCell()
        cell.identifier = .init("cell"); cell.filename.stringValue = item.url.lastPathComponent; cell.filename.toolTip = item.url.path
        if cropSelection != nil, let plan = plan {
            cell.details.stringValue = "\(item.width) × \(item.height) · Crop \(plan.cropWidth) × \(plan.cropHeight)"
        } else {
            cell.details.stringValue = item.isInspected ? "\(item.width) × \(item.height) · \(ByteCountFormatter.string(fromByteCount: item.fileBytes, countStyle: .file))" : ""
        }
        cell.details.toolTip = cell.details.stringValue
        cell.thumbnail.image = thumbnails[item.id]
        requestThumbnail(item)
        cell.result.toolTip = nil
        if let result = rowResults[item.id] { cell.result.stringValue = result }
        else if let target = plan {
            cell.result.stringValue = target.skipped ? "Will skip" : "→ \(target.width) × \(target.height)"
        }
        else { cell.result.stringValue = "" }
        if rowResults[item.id] == nil && plan?.skipped != true && validationMessage() == nil {
            let suffix: String
            switch outputEstimates.value(for: item.id) {
            case .ready(let estimate):
                if estimate.skipped { suffix = "Will skip" }
                else {
                    suffix = "~\(ByteCountFormatter.string(fromByteCount: estimate.outputBytes, countStyle: .file))"
                    cell.result.toolTip = "Estimated output: \(estimate.outputBytes) bytes\(estimate.formatExtension.map { " · \($0.uppercased())" } ?? ""). Based on the current export settings."
                }
            case .unavailable(let reason): suffix = "Size unavailable"; cell.result.toolTip = reason
            case nil: suffix = busy ? "" : "Estimating…"
            }
            if !suffix.isEmpty { cell.result.stringValue += (cell.result.stringValue.isEmpty ? "" : "\n") + suffix }
        }
        cell.result.textColor = errorIDs.contains(item.id) ? .systemRed : .secondaryLabelColor
        return cell
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let editor = cropEditor?.window { editor.makeKeyAndOrderFront(nil) }
        else if let loading = cropLoadingPanel { loading.makeKeyAndOrderFront(nil) }
        else if let preview = previewPanel { preview.makeKeyAndOrderFront(nil) }
        else { window.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        savePreferences()
        guard busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop processing and quit?"; alert.informativeText = "The current image will finish before the app closes."
        alert.addButton(withTitle: "Keep Resizing"); alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            quitAfterBatch = true; token?.cancel()
            if pendingBatch != nil { pendingBatch = nil; return .terminateNow }
            return .terminateLater
        }
        window.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        savePreferences(); pauseEstimates(); discoveryCancellation.cancel(); thumbnailCancellation.cancel(); previewCancellation?.cancel(); cropCancellation?.cancel()
    }
}

@main
struct ImageResizeApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
