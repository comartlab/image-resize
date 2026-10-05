// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers
import Darwin

enum ResizeMode: String, CaseIterable {
    case longestEdge, fit, width, height, percent, originalDimensions
}

enum OutputFormat: String, CaseIterable {
    case original, jpeg, png, tiff, heic, web
}

struct ResizeSettings {
    var mode: ResizeMode = .longestEdge
    var width: Int = 1600
    var height: Int = 1600
    var percent: Double = 50
    var format: OutputFormat = .jpeg
    var quality: Double = 0.9
    var webQuality: Double = 0.75
    var preserveMetadata: Bool = true
    var watermarkEnabled: Bool = false
    var watermarkText: String = ""
    var watermarkStrength: Double = 0.25
    var crop: CropSelection? = nil
}

struct ImageItem: Identifiable {
    let id: UUID
    let url: URL
    /// Displayed dimensions, accounting for EXIF orientation.
    let width: Int
    let height: Int
    let fileBytes: Int64
    let typeIdentifier: String

    /// Queued entries carry only a URL until processing inspects the source.
    var isInspected: Bool { width > 0 && height > 0 && !typeIdentifier.isEmpty }

    /// This performs no filesystem reads, image parsing, or validation.
    static func queued(_ url: URL, id: UUID = UUID()) -> ImageItem {
        ImageItem(id: id, url: url, width: 0, height: 0, fileBytes: 0, typeIdentifier: "")
    }

    init(id: UUID = UUID(), url: URL, width: Int, height: Int,
         fileBytes: Int64, typeIdentifier: String) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.fileBytes = fileBytes
        self.typeIdentifier = typeIdentifier
    }
}

struct ResizeResult {
    let source: URL
    let output: URL?
    let width: Int
    let height: Int
    let inputBytes: Int64
    let outputBytes: Int64
    /// True when a reduction mode needs no shrink and writes no output file.
    let skipped: Bool
    let message: String
}

struct OutputSizeEstimate {
    let width: Int
    let height: Int
    let outputBytes: Int64
    let skipped: Bool
    let formatExtension: String?
}

enum ResizeError: Error, LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case multipleImages(String, Int)
    case invalidSettings(String)
    case decode(String)
    case photoshopComposite(String)
    case allocation
    case processing(Int)
    case encode(String)
    case output(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Cannot read \(name)."
        case .unsupported(let name): return "\(name) is not a supported image."
        case .multipleImages(let name, let count):
            return "\(name) contains \(count) frames or pages. Animated and multipage images are not resized."
        case .invalidSettings(let reason): return reason
        case .decode(let name): return "Cannot decode \(name). The image may be damaged."
        case .photoshopComposite(let name):
            return "\(name) has no usable flattened Photoshop composite. Save it with Maximize Compatibility enabled, or export a flattened TIFF."
        case .allocation: return "There is not enough available memory to resize this image."
        case .processing(let code): return "Image processing failed (\(code))."
        case .encode(let type):
            if type.lowercased() == "heic" {
                return "HEIC encoding is unavailable on this Mac. Choose JPEG or PNG."
            }
            return "macOS could not encode this image as \(type)."
        case .output(let reason): return "Cannot save the image: \(reason)"
        }
    }
}

/// ImageIO decoding and encoding, CoreGraphics color management, and native
/// Accelerate Lanczos-5 reduction. Premultiplied buffers preserve translucent
/// edges; ordinary 8-bit images use compact byte buffers, while high-depth
/// images retain floating-point precision during processing.
final class ResizeEngine {
    private static let manager = FileManager.default
    private static let floatBitmapInfo = CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    private static let byteBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue

    static func inspect(_ url: URL) throws -> ImageItem {
        let source = try openSource(url)
        let properties = try imageProperties(source, name: url.lastPathComponent)
        guard let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0,
              let type = CGImageSourceGetType(source) as String? else {
            if isPhotoshop(source) { throw ResizeError.photoshopComposite(url.lastPathComponent) }
            throw ResizeError.unsupported(url.lastPathComponent)
        }
        let rotated = orientation(properties) >= 5
        return ImageItem(url: url, width: rotated ? height : width,
                         height: rotated ? width : height,
                         fileBytes: try fileSize(url), typeIdentifier: type)
    }

    /// Refresh source metadata without replacing the queue entry's identity.
    static func inspect(_ item: ImageItem) throws -> ImageItem {
        let inspected = try inspect(item.url)
        return ImageItem(id: item.id, url: inspected.url, width: inspected.width,
                         height: inspected.height, fileBytes: inspected.fileBytes,
                         typeIdentifier: inspected.typeIdentifier)
    }

    static func targetSize(width: Int, height: Int, settings: ResizeSettings) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else {
            throw ResizeError.invalidSettings("Image dimensions must be positive.")
        }
        var scale: Double
        switch settings.mode {
        case .longestEdge:
            guard settings.width > 0 else { throw ResizeError.invalidSettings("Enter a positive longest edge.") }
            scale = Double(settings.width) / Double(max(width, height))
        case .fit:
            guard settings.width > 0, settings.height > 0 else {
                throw ResizeError.invalidSettings("Enter a positive width and height.")
            }
            scale = min(Double(settings.width) / Double(width), Double(settings.height) / Double(height))
        case .width:
            guard settings.width > 0 else { throw ResizeError.invalidSettings("Enter a positive width.") }
            scale = Double(settings.width) / Double(width)
        case .height:
            guard settings.height > 0 else { throw ResizeError.invalidSettings("Enter a positive height.") }
            scale = Double(settings.height) / Double(height)
        case .percent:
            guard settings.percent.isFinite, settings.percent > 0 else {
                throw ResizeError.invalidSettings("Enter a positive percentage.")
            }
            scale = settings.percent / 100
        case .originalDimensions:
            return (width, height)
        }
        scale = min(1, scale)
        // Aspect ratio is retained to the nearest whole pixel; upscaling is
        // disallowed even when the requested bound is larger than the source.
        var resultWidth = roundedDimension(width, scale: scale)
        var resultHeight = roundedDimension(height, scale: scale)
        switch settings.mode {
        case .longestEdge:
            resultWidth = min(resultWidth, settings.width)
            resultHeight = min(resultHeight, settings.width)
        case .fit:
            resultWidth = min(resultWidth, settings.width)
            resultHeight = min(resultHeight, settings.height)
        case .width: resultWidth = min(resultWidth, settings.width)
        case .height: resultHeight = min(resultHeight, settings.height)
        case .percent, .originalDimensions: break
        }
        return (resultWidth, resultHeight)
    }

    private static func roundedDimension(_ original: Int, scale: Double) -> Int {
        let rounded = (Double(original) * scale).rounded()
        // Double(Int.max) rounds up past Int's range. Compare before converting
        // so representable positive dimensions remain safe near that boundary.
        if rounded >= Double(original) { return original }
        return max(1, Int(rounded))
    }

    /// Plan against the oriented crop before applying the no-upscale rule.
    static func outputPlan(width: Int, height: Int, settings: ResizeSettings) throws -> ResizeOutputPlan {
        guard width > 0, height > 0 else {
            throw ResizeError.invalidSettings("Image dimensions must be positive.")
        }
        let crop = try settings.crop?.pixelBounds(width: width, height: height)
            ?? (x: 0, y: 0, width: width, height: height)
        let target = try targetSize(width: crop.width, height: crop.height, settings: settings)
        return ResizeOutputPlan(cropRect: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height),
                                cropWidth: crop.width, cropHeight: crop.height,
                                width: target.width, height: target.height,
                                skipped: settings.mode != .originalDimensions && target.width == crop.width && target.height == crop.height,
                                isCropped: crop.x != 0 || crop.y != 0 || crop.width != width || crop.height != height)
    }

    /// An explicitly requested source preview uses the export normalization
    /// path, independent of crop, watermark, output format, and fitting skips.
    static func sourcePreview(_ item: ImageItem, maxPixelDimension: Int = 1600) throws -> (ImageItem, CGImage) {
        guard maxPixelDimension > 0 else {
            throw ResizeError.invalidSettings("Enter a positive preview size.")
        }
        let current = try inspect(item)
        let source = try openSource(item.url)
        let properties = try imageProperties(source, name: item.url.lastPathComponent)
        let composite = try decodedComposite(source, name: item.url.lastPathComponent)
        var settings = ResizeSettings()
        settings.mode = .longestEdge
        settings.width = maxPixelDimension
        let target = try targetSize(width: current.width, height: current.height, settings: settings)
        let result = try reducedImage(composite, orientation: orientation(properties),
                                      cropRect: CGRect(x: 0, y: 0, width: current.width, height: current.height),
                                      cropWidth: current.width, cropHeight: current.height,
                                      width: target.width, height: target.height,
                                      outputType: UTType.png.identifier,
                                      photoshopWhiteMatte: isPhotoshop(source) && composite.colorSpace?.model == .rgb && hasAlpha(composite))
        return (current, result.image)
    }

    /// Trial-encode the exact export settings without using the user's output
    /// folder. Only our UUID child is removed; temporaryRoot itself is retained.
    static func estimateOutput(_ item: ImageItem, settings: ResizeSettings,
                               cancelled: () -> Bool = { false },
                               onInspect: ((ImageItem) -> Void)? = nil,
                               temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> OutputSizeEstimate {
        try checkCancellation(cancelled)
        let folder = temporaryRoot.appendingPathComponent("ImageResize-estimate-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let result = try resize(item, to: folder, settings: settings, onInspect: onInspect, cancelled: cancelled)
        try checkCancellation(cancelled)
        return OutputSizeEstimate(width: result.width, height: result.height,
                                  outputBytes: result.outputBytes, skipped: result.skipped,
                                  formatExtension: result.output?.pathExtension)
    }

    private static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }

    /// onInspect runs synchronously on the caller's processing worker after
    /// fresh inspection, before size decisions or pixel decoding. UI callers
    /// should dispatch their stable-ID row update to the main queue.
    static func resize(_ item: ImageItem, to folder: URL, settings: ResizeSettings,
                       onInspect: ((ImageItem) -> Void)? = nil,
                       cancelled: () -> Bool = { false }) throws -> ResizeResult {
        try checkCancellation(cancelled)
        let optimizedForWeb = settings.format == .web
        let quality = optimizedForWeb ? settings.webQuality : settings.quality
        guard quality.isFinite, (0...1).contains(quality) else {
            throw ResizeError.invalidSettings("Image quality must be between 0 and 100 percent.")
        }
        if settings.watermarkEnabled {
            try TextWatermark.validate(settings.watermarkText, strength: settings.watermarkStrength)
        }
        let watermarkIsVisible = settings.watermarkEnabled && settings.watermarkStrength > 0
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard folder.isFileURL, values.isDirectory == true else {
            throw ResizeError.output("choose an existing output folder.")
        }
        // Re-inspect when processing: the source may have changed since import.
        let current = try inspect(item)
        onInspect?(current)
        try checkCancellation(cancelled)
        let target = try outputPlan(width: current.width, height: current.height, settings: settings)
        if target.skipped {
            return ResizeResult(source: item.url, output: nil, width: target.width, height: target.height,
                                inputBytes: current.fileBytes, outputBytes: 0,
                                skipped: true, message: "Already at or below the selected size; skipped.")
        }

        let source = try openSource(item.url)
        let properties = try imageProperties(source, name: item.url.lastPathComponent)
        let photoshop = isPhotoshop(source)
        // ImageIO supplies the saved visible composite for PSD and layered
        // TIFF. Rendering it into our own pixel buffer flattens the document
        // before reduction, retaining Photoshop's baked masks and effects.
        try checkCancellation(cancelled)
        let composite = try decodedComposite(source, name: item.url.lastPathComponent)
        try checkCancellation(cancelled)
        let photoshopWhiteMatte = photoshop && composite.colorSpace?.model == .rgb && hasAlpha(composite)
        var outputType = try destinationType(settings.format, original: current.typeIdentifier)
        var result = try reducedImage(composite, orientation: orientation(properties),
                                      cropRect: target.cropRect, cropWidth: target.cropWidth, cropHeight: target.cropHeight,
                                      width: target.width, height: target.height,
                                      outputType: outputType.identifier,
                                      watermarkText: watermarkIsVisible ? settings.watermarkText : nil,
                                      watermarkStrength: settings.watermarkStrength,
                                      photoshopWhiteMatte: photoshopWhiteMatte,
                                      optimizedForWeb: optimizedForWeb,
                                      cancelled: cancelled)
        try checkCancellation(cancelled)
        if settings.format == .original && photoshop && result.transparent {
            // ImageIO's PSD writer stores a straight-alpha composite that
            // differs from Photoshop's white-matted merged transparency.
            // Use a flat format that preserves alpha accurately on reimport.
            outputType = (UTType.png.identifier, "png", "Saved as PNG because the native PSD writer cannot preserve transparent composites accurately.")
            result = try reducedImage(composite, orientation: orientation(properties),
                                      cropRect: target.cropRect, cropWidth: target.cropWidth, cropHeight: target.cropHeight,
                                      width: target.width, height: target.height,
                                      outputType: outputType.identifier,
                                      watermarkText: watermarkIsVisible ? settings.watermarkText : nil,
                                      watermarkStrength: settings.watermarkStrength,
                                      photoshopWhiteMatte: photoshopWhiteMatte,
                                      cancelled: cancelled)
        }
        try checkCancellation(cancelled)
        let staged = try temporaryFile(in: folder)
        defer { try? manager.removeItem(at: staged) }
        if optimizedForWeb {
            outputType = try encodeForWeb(result.image, to: staged, quality: quality,
                                         transparent: result.transparent, cancelled: cancelled)
        } else {
            do {
                try encode(result.image, to: staged, type: outputType, source: source,
                           properties: properties, settings: settings,
                           width: target.width, height: target.height, cropped: target.isCropped,
                           cancelled: cancelled)
            } catch {
                guard settings.format == .original, outputType.identifier != UTType.png.identifier,
                      case ResizeError.encode = error else { throw error }
                outputType = (UTType.png.identifier, "png", "macOS could not write the original format; saved as PNG.")
                result = try reducedImage(composite, orientation: orientation(properties),
                                          cropRect: target.cropRect, cropWidth: target.cropWidth, cropHeight: target.cropHeight,
                                          width: target.width, height: target.height,
                                          outputType: outputType.identifier,
                                          watermarkText: watermarkIsVisible ? settings.watermarkText : nil,
                                          watermarkStrength: settings.watermarkStrength,
                                          photoshopWhiteMatte: photoshopWhiteMatte,
                                          cancelled: cancelled)
                try encode(result.image, to: staged, type: outputType, source: source,
                           properties: properties, settings: settings,
                           width: target.width, height: target.height, cropped: target.isCropped,
                           cancelled: cancelled)
            }
        }
        try checkCancellation(cancelled)
        let output = try publish(staged, in: folder,
                                 stem: item.url.deletingPathExtension().lastPathComponent,
                                 extension: outputType.extension)
        var notes = [String]()
        if let note = outputType.note { notes.append(note) }
        notes.append(contentsOf: result.notes)
        if target.isCropped { notes.insert("Cropped.", at: 0) }
        if watermarkIsVisible { notes.insert("Watermarked.", at: 0) }
        let defaultMessage = settings.mode == .originalDimensions ? "Saved." : "Resized."
        return ResizeResult(source: item.url, output: output, width: target.width, height: target.height,
                            inputBytes: current.fileBytes, outputBytes: try fileSize(output),
                            skipped: false, message: notes.isEmpty ? defaultMessage : notes.joined(separator: " "))
    }

    private static func encode(_ image: CGImage, to staged: URL,
                               type outputType: (identifier: String, extension: String, note: String?),
                               source: CGImageSource, properties: [String: Any], settings: ResizeSettings,
                               width: Int, height: Int, cropped: Bool,
                               cancelled: () -> Bool) throws {
        try checkCancellation(cancelled)
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL,
                  outputType.identifier as CFString, 1, nil) else {
            throw ResizeError.encode(outputType.extension)
        }
        let outputProperties = metadata(properties, preserving: settings.preserveMetadata,
                                        width: width, height: height,
                                        depth: image.bitsPerComponent, quality: settings.quality, cropped: cropped)
        if settings.preserveMetadata,
           let originalMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let updated = CGImageMetadataCreateMutableCopy(originalMetadata) {
            updateMetadata(updated, width: width, height: height, cropped: cropped)
            CGImageDestinationAddImageAndMetadata(destination, image, updated, outputProperties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        }
        try checkCancellation(cancelled)
        guard CGImageDestinationFinalize(destination) else { throw ResizeError.encode(outputType.extension) }
        try checkCancellation(cancelled)
    }

    /// Rendered dimensions and pixels are shared by every candidate. Keep just
    /// the best file plus one temporary candidate on disk; no encoded Data or
    /// second image rendering is needed to compare their actual byte counts.
    private static func encodeForWeb(_ image: CGImage, to staged: URL, quality: Double,
                                     transparent: Bool, cancelled: () -> Bool) throws -> (identifier: String, `extension`: String, note: String?) {
        try checkCancellation(cancelled)
        let candidateImage: CGImage
        if transparent {
            candidateImage = image
        } else {
            // The final alpha scan proves every alpha byte is 255. Relabel the
            // same provider as RGB so PNG need not store an unused alpha plane.
            guard let space = image.colorSpace, let provider = image.dataProvider,
                  let opaque = CGImage(width: image.width, height: image.height,
                      bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                      bytesPerRow: image.bytesPerRow, space: space,
                      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw ResizeError.allocation
            }
            candidateImage = opaque
        }
        try encodeWebCandidate(candidateImage, to: staged, type: UTType.png.identifier,
                               quality: quality, progressive: false, cancelled: cancelled)
        var winner = (identifier: UTType.png.identifier, extension: "png",
                      note: Optional("Optimized for web as lossless PNG. sRGB, 8-bit color; metadata removed."))
        if transparent { return winner }
        var smallest = try fileSize(staged)
        for progressive in [false, true] {
            try checkCancellation(cancelled)
            let candidate = try temporaryFile(in: staged.deletingLastPathComponent())
            defer { try? manager.removeItem(at: candidate) }
            do {
                try encodeWebCandidate(candidateImage, to: candidate, type: UTType.jpeg.identifier,
                                       quality: quality, progressive: progressive, cancelled: cancelled)
            } catch {
                // PNG is already a valid lossless output. A native JPEG codec
                // failure should not discard it or create a partial output.
                guard case ResizeError.encode = error else { throw error }
                continue
            }
            let count = try fileSize(candidate)
            if count < smallest {
                guard rename(candidate.path, staged.path) == 0 else { throw posixOutputError() }
                smallest = count
                let method = progressive ? "progressive JPEG" : "JPEG"
                winner = (UTType.jpeg.identifier, "jpg",
                          "Optimized for web as \(method). sRGB, 8-bit color; metadata removed.")
            }
        }
        return winner
    }

    private static func encodeWebCandidate(_ image: CGImage, to staged: URL, type: String,
                                           quality: Double, progressive: Bool, cancelled: () -> Bool) throws {
        try checkCancellation(cancelled)
        let ext = type == UTType.jpeg.identifier ? "jpg" : "png"
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, type as CFString, 1, nil) else {
            throw ResizeError.encode(ext)
        }
        var properties = metadata([:], preserving: false, width: image.width, height: image.height,
                                  depth: 8, quality: quality, cropped: false)
        properties[kCGImageDestinationEmbedThumbnail as String] = false
        if type == UTType.jpeg.identifier {
            properties[kCGImagePropertyJFIFDictionary as String] = [kCGImagePropertyJFIFIsProgressive as String: progressive]
        } else {
            properties[kCGImagePropertyPNGCompressionFilter as String] = IMAGEIO_PNG_FILTER_NONE
                | IMAGEIO_PNG_FILTER_SUB | IMAGEIO_PNG_FILTER_UP | IMAGEIO_PNG_FILTER_AVG | IMAGEIO_PNG_FILTER_PAETH
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try checkCancellation(cancelled)
        guard CGImageDestinationFinalize(destination) else { throw ResizeError.encode(ext) }
        try checkCancellation(cancelled)
    }

    private static func openSource(_ url: URL) throws -> CGImageSource {
        guard url.isFileURL, manager.isReadableFile(atPath: url.path) else {
            throw ResizeError.unreadable(url.lastPathComponent)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ResizeError.unsupported(url.lastPathComponent)
        }
        // Adobe resource 1057 identifies compatibility placeholders. Native
        // fallback layer composition does not reliably preserve visibility,
        // opacity, masks, or effects, so require the saved visible composite.
        if isPhotoshop(source) && photoshopHasNoMergedData(url) {
            throw ResizeError.photoshopComposite(url.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else {
            if isPhotoshop(source) { throw ResizeError.photoshopComposite(url.lastPathComponent) }
            if count > 1 { throw ResizeError.multipleImages(url.lastPathComponent, count) }
            throw ResizeError.unsupported(url.lastPathComponent)
        }
        return source
    }

    private static func imageProperties(_ source: CGImageSource, name: String) throws -> [String: Any] {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            if isPhotoshop(source) { throw ResizeError.photoshopComposite(name) }
            throw ResizeError.decode(name)
        }
        return properties
    }

    private static func isPhotoshop(_ source: CGImageSource) -> Bool {
        CGImageSourceGetType(source) as String? == "com.adobe.photoshop-image"
    }

    private static func decodedComposite(_ source: CGImageSource, name: String) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true,
             kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            if isPhotoshop(source) { throw ResizeError.photoshopComposite(name) }
            throw ResizeError.decode(name)
        }
        guard isPhotoshop(source) else { return image }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ResizeError.photoshopComposite(name)
        }
        return try normalizedPhotoshopImage(image, name: name)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }

    private static func normalizedPhotoshopImage(_ image: CGImage, name: String) throws -> CGImage {
        guard hasAlpha(image), let space = image.colorSpace else { return image }
        if space.model == .cmyk {
            if image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast {
                return image
            }
            // PSD stores inverted CMYK. After inversion, the native provider's
            // ink components are alpha-associated even though CMYK alpha is
            // labelled straight. Unassociate ink in CMYK before ColorSync;
            // unmatting the converted RGB would change the intended color.
            return try normalizedNonRGBPhotoshopImage(image, name: name, unassociateInk: true)
        }
        if space.model == .monochrome, image.bitsPerComponent == 16,
           image.alphaInfo == .first || image.alphaInfo == .last {
            // Native 16-bit gray remains white-matted straight data. Remove
            // the matte in gray, retaining high-depth precision, then label
            // the resulting alpha-associated gray correctly before conversion.
            return try normalizedNonRGBPhotoshopImage(image, name: name, unassociateInk: false)
        }
        // The incorrect provider label is specific to the 8-bit native PSD
        // RGB/gray decoder. Its 16-bit RGB decoder supplies straight-alpha data.
        guard image.bitsPerComponent == 8 else { return image }
        let corrected: CGImageAlphaInfo
        switch image.alphaInfo {
        case .last: corrected = .premultipliedLast
        case .first: corrected = .premultipliedFirst
        default: return image
        }
        // ImageIO's PSD decoder emits premultiplied provider data while its
        // CGImage reports straight alpha. Correct that label before drawing,
        // which otherwise applies alpha a second time and darkens the image.
        guard let provider = image.dataProvider,
              let result = CGImage(width: image.width, height: image.height,
                  bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                  bytesPerRow: image.bytesPerRow, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)
                      | corrected.rawValue), provider: provider, decode: image.decode,
                  shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
            throw ResizeError.photoshopComposite(name)
        }
        return result
    }

    private static func normalizedNonRGBPhotoshopImage(_ image: CGImage, name: String,
                                                       unassociateInk: Bool) throws -> CGImage {
        guard let space = image.colorSpace, let data = image.dataProvider?.data,
              image.bitsPerComponent == 8 || image.bitsPerComponent == 16 else {
            throw ResizeError.photoshopComposite(name)
        }
        let depth = image.bitsPerComponent
        let components = space.numberOfComponents + 1
        let componentBytes = depth / 8
        let (count, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, count > 0, image.bitsPerPixel == components * depth,
              CFDataGetLength(data) >= count, let sourceBytes = CFDataGetBytePtr(data) else {
            throw ResizeError.photoshopComposite(name)
        }
        guard let bytes = malloc(count) else { throw ResizeError.allocation }
        var providerOwnsBytes = false
        defer { if !providerOwnsBytes { free(bytes) } }
        memcpy(bytes, sourceBytes, count)
        let alphaFirst = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst
        let alphaIndex = alphaFirst ? 0 : components - 1
        let maximum = depth == 8 ? 255 : 65535
        let bigEndian = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Big
        func readComponent(_ pixel: UnsafeMutableRawPointer, _ channel: Int) -> Int {
            let address = pixel.advanced(by: channel * componentBytes)
            if depth == 8 { return Int(address.load(as: UInt8.self)) }
            let value = address.load(as: UInt16.self)
            return Int(bigEndian ? UInt16(bigEndian: value) : UInt16(littleEndian: value))
        }
        func writeComponent(_ pixel: UnsafeMutableRawPointer, _ channel: Int, _ value: Int) {
            let address = pixel.advanced(by: channel * componentBytes)
            if depth == 8 { address.storeBytes(of: UInt8(value), as: UInt8.self) }
            else {
                let value = UInt16(value)
                address.storeBytes(of: bigEndian ? value.bigEndian : value.littleEndian, as: UInt16.self)
            }
        }
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = bytes.advanced(by: y * image.bytesPerRow + x * components * componentBytes)
                let alpha = readComponent(pixel, alphaIndex)
                for channel in 0..<components where channel != alphaIndex {
                    let value = readComponent(pixel, channel)
                    let corrected = alpha == 0 ? 0 : unassociateInk
                        ? min(maximum, Int((Double(value) * Double(maximum) / Double(alpha)).rounded()))
                        : max(0, value - (maximum - alpha))
                    writeComponent(pixel, channel, corrected)
                }
            }
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: bytes, size: count,
                  releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else {
            throw ResizeError.allocation
        }
        providerOwnsBytes = true
        let alpha: CGImageAlphaInfo = unassociateInk ? (alphaFirst ? .first : .last)
            : (alphaFirst ? .premultipliedFirst : .premultipliedLast)
        guard let result = CGImage(width: image.width, height: image.height,
                  bitsPerComponent: depth, bitsPerPixel: image.bitsPerPixel,
                  bytesPerRow: image.bytesPerRow, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)
                      | alpha.rawValue), provider: provider, decode: image.decode,
                  shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
            throw ResizeError.photoshopComposite(name)
        }
        return result
    }

    /// Read only PSD headers and resource descriptors, seeking over payloads.
    /// All offsets are checked against actual file/resource lengths; no image
    /// dimension or input-size policy limits are imposed.
    private static func photoshopHasNoMergedData(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd(), (try? file.seek(toOffset: 0)) != nil else { return false }
        var cursor: UInt64 = 0
        var limit = length
        func read(_ count: Int) -> Data? {
            guard UInt64(count) <= limit - min(cursor, limit),
                  let data = try? file.read(upToCount: count), data.count == count else { return nil }
            cursor += UInt64(count)
            return data
        }
        func number(_ count: Int) -> UInt64? {
            read(count)?.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func skip(_ count: UInt64) -> Bool {
            let (end, overflow) = cursor.addingReportingOverflow(count)
            guard !overflow, end <= limit, (try? file.seek(toOffset: end)) != nil else { return false }
            cursor = end
            return true
        }
        guard let header = read(26), header.prefix(4) == Data("8BPS".utf8),
              header[4] == 0, header[5] == 1 || header[5] == 2,
              let colorLength = number(4), skip(colorLength), let resourceLength = number(4),
              resourceLength <= length - cursor else { return false }
        limit = cursor + resourceLength
        while cursor < limit {
            guard read(4) == Data("8BIM".utf8), let identifier = number(2),
                  let nameLength = number(1), skip(nameLength + ((nameLength + 1) % 2)),
                  let dataLength = number(4), dataLength <= limit - cursor else { return false }
            if identifier == 1057 && dataLength >= 5 {
                guard let versionInfo = read(5) else { return false }
                if versionInfo[4] == 0 { return true }
                guard skip(dataLength - 5 + dataLength % 2) else { return false }
            } else if !skip(dataLength + dataLength % 2) { return false }
        }
        return false
    }

    private static func orientation(_ properties: [String: Any]) -> Int {
        let value = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        return (1...8).contains(value) ? value : 1
    }

    private static func destinationType(_ requested: OutputFormat, original: String)
        throws -> (identifier: String, `extension`: String, note: String?) {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        let identifier: String
        switch requested {
        case .original: identifier = original
        case .jpeg: identifier = UTType.jpeg.identifier
        case .png: identifier = UTType.png.identifier
        case .tiff: identifier = UTType.tiff.identifier
        case .heic: identifier = UTType.heic.identifier
        // Web rendering initially retains alpha. Its encoder chooses the
        // final JPEG or PNG container from the actual output pixels and size.
        case .web: identifier = UTType.png.identifier
        }
        if writable.contains(identifier) {
            // PSD's UTI is not always registered for standalone executables.
            // Its filename must not depend on Launch Services registration.
            let ext: String
            switch identifier {
            case "com.adobe.photoshop-image": ext = "psd"
            case UTType.jpeg.identifier: ext = "jpg"
            default: ext = UTType(identifier)?.preferredFilenameExtension ?? "img"
            }
            return (identifier, ext, nil)
        }
        guard requested == .original, writable.contains(UTType.png.identifier) else {
            throw ResizeError.encode(requested.rawValue.uppercased())
        }
        return (UTType.png.identifier, "png", "The original format cannot be written by macOS; saved as PNG.")
    }

    private static func reducedImage(_ image: CGImage, orientation: Int,
                                     cropRect: CGRect, cropWidth: Int, cropHeight: Int, width: Int, height: Int,
                                     outputType: String, watermarkText: String? = nil,
                                     watermarkStrength: Double = 0.25,
                                     photoshopWhiteMatte: Bool = false,
                                     optimizedForWeb: Bool = false,
                                     cancelled: () -> Bool = { false }) throws -> (image: CGImage, notes: [String], transparent: Bool) {
        try checkCancellation(cancelled)
        let sourceWidth = cropWidth
        let sourceHeight = cropHeight
        let byteProcessing = image.bitsPerComponent <= 8 && !image.bitmapInfo.contains(.floatComponents)
        let processingDepth = byteProcessing ? 8 : 32
        let processingPixelBits = byteProcessing ? 32 : 128
        let processingInfo = byteProcessing ? byteBitmapInfo : floatBitmapInfo
        let sourceSpace = image.colorSpace
        let convertedColor = sourceSpace?.model != .rgb
        guard let space = convertedColor ? CGColorSpace(name: CGColorSpace.sRGB) : sourceSpace else {
            throw ResizeError.decode("the image color profile")
        }

        var input = vImage_Buffer()
        var output = vImage_Buffer()
        let needsResampling = sourceWidth != width || sourceHeight != height
        var status = vImageBuffer_Init(&output, vImagePixelCount(height), vImagePixelCount(width),
                                      UInt32(processingPixelBits), vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw ResizeError.allocation }
        defer { free(output.data) }
        let outputByteCount = try bufferByteCount(output)
        defer { free(input.data) }
        if needsResampling {
            status = vImageBuffer_Init(&input, vImagePixelCount(sourceHeight), vImagePixelCount(sourceWidth),
                                      UInt32(processingPixelBits), vImage_Flags(kvImageNoFlags))
            guard status == kvImageNoError else { throw ResizeError.allocation }
            _ = try bufferByteCount(input)
        }
        // Draw directly into the final working buffer when preserving pixel
        // dimensions. This avoids both a second buffer and any resampling.
        let drawingBuffer = needsResampling ? input : output
        try drawSource(image, orientation: orientation, cropRect: cropRect, in: drawingBuffer, space: space,
                       depth: processingDepth, bitmapInfo: processingInfo)
        if photoshopWhiteMatte { removePhotoshopWhiteMatte(from: drawingBuffer, byteProcessing: byteProcessing) }
        try checkCancellation(cancelled)

        if needsResampling {
            if byteProcessing {
                status = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            } else {
                status = vImageScale_ARGBFFFF(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
            // drawSource's context is gone and vImage has finished reading input.
            // Release the full-resolution working buffer before finishing output.
            free(input.data)
            input.data = nil
            guard status == kvImageNoError else { throw ResizeError.processing(Int(status)) }
        }
        try checkCancellation(cancelled)
        // Lanczos has negative lobes: constrain premultiplied SDR pixels after
        // filtering so faint alpha overshoot cannot produce edge artifacts.
        var transparent = false
        var extendedRange = false
        if byteProcessing {
            for y in 0..<height {
                let pixels = output.data.advanced(by: y * output.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let offset = x * 4
                    let alpha = pixels[offset + 3]
                    if alpha < 255 { transparent = true }
                    for channel in 0..<3 { pixels[offset + channel] = min(alpha, pixels[offset + channel]) }
                }
            }
        } else {
            for y in 0..<height {
                let pixels = output.data.advanced(by: y * output.rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    let offset = x * 4
                    let rawAlpha = pixels[offset + 3]
                    let alpha = min(1, max(0, rawAlpha.isFinite ? rawAlpha : 0))
                    if alpha < 0.99999 { transparent = true }
                    pixels[offset + 3] = alpha
                    for channel in 0..<3 {
                        let value = pixels[offset + channel]
                        if value > alpha + 0.001 { extendedRange = true }
                        pixels[offset + channel] = min(alpha, max(0, value.isFinite ? value : 0))
                    }
                }
            }
        }
        try checkCancellation(cancelled)
        if let watermarkText = watermarkText {
            guard let watermarkContext = CGContext(data: output.data, width: width, height: height,
                      bitsPerComponent: processingDepth, bytesPerRow: output.rowBytes, space: space,
                      bitmapInfo: processingInfo) else { throw ResizeError.allocation }
            try TextWatermark.draw(text: watermarkText, in: watermarkContext, width: width, height: height,
                                   strength: watermarkStrength)
            watermarkContext.flush()
        }
        try checkCancellation(cancelled)
        guard let provider = CGDataProvider(dataInfo: nil, data: output.data,
                  size: outputByteCount, releaseData: { _, _, _ in }),
              let processedImage = CGImage(width: width, height: height, bitsPerComponent: processingDepth,
                  bitsPerPixel: processingPixelBits, bytesPerRow: output.rowBytes, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: processingInfo), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ResizeError.allocation
        }
        let highDepth = image.bitsPerComponent > 8
        let accepts16 = !optimizedForWeb && (outputType == UTType.png.identifier || outputType == UTType.tiff.identifier)
        let depth = highDepth && accepts16 ? 16 : 8
        let flatten = outputType == UTType.jpeg.identifier || outputType == UTType.heic.identifier
        let alphaInfo = flatten ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        let integerInfo = alphaInfo.rawValue | (depth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
            | (optimizedForWeb ? CGBitmapInfo.byteOrder32Big.rawValue : 0)
        // Photoshop's white matte must be removed in its original RGB space.
        // Convert only the finished, oriented/cropped/filtered pixels to sRGB.
        guard let encodingSpace = optimizedForWeb ? CGColorSpace(name: CGColorSpace.sRGB) : space else {
            throw ResizeError.decode("the image color profile")
        }
        guard let encodedContext = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: depth, bytesPerRow: 0, space: encodingSpace, bitmapInfo: integerInfo) else {
            throw ResizeError.allocation
        }
        if flatten {
            encodedContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            encodedContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        encodedContext.interpolationQuality = .none
        encodedContext.draw(processedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        try checkCancellation(cancelled)
        if optimizedForWeb {
            encodedContext.flush()
            guard let data = encodedContext.data else { throw ResizeError.allocation }
            transparent = false
            // Alpha after watermark rendering and 8-bit quantization decides
            // the format. An alpha channel alone does not imply transparency.
            alphaScan: for y in 0..<height {
                let pixels = data.advanced(by: y * encodedContext.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where pixels[x * 4 + 3] < 255 {
                    transparent = true
                    break alphaScan
                }
            }
        }
        guard let result = encodedContext.makeImage() else { throw ResizeError.allocation }
        var notes = [String]()
        if convertedColor { notes.append("Converted to sRGB.") }
        if flatten && transparent { notes.append("Transparency flattened onto white.") }
        if highDepth && !accepts16 { notes.append("Saved with 8-bit color.") }
        if image.bitsPerComponent > 16 && accepts16 { notes.append("Saved with 16-bit color.") }
        if extendedRange && image.bitmapInfo.contains(.floatComponents) {
            notes.append("Extended-range pixels converted to SDR.")
        }
        return (result, notes, transparent)
    }

    private static func bufferByteCount(_ buffer: vImage_Buffer) throws -> Int {
        let (count, overflow) = buffer.rowBytes.multipliedReportingOverflow(by: Int(buffer.height))
        guard !overflow, count > 0 else { throw ResizeError.allocation }
        return count
    }

    private static func removePhotoshopWhiteMatte(from buffer: vImage_Buffer, byteProcessing: Bool) {
        // Photoshop's merged transparency is matted with white. Convert that
        // composite to ordinary premultiplied RGBA before filtering; transparent
        // edges then retain their color on both light and dark backgrounds.
        for y in 0..<Int(buffer.height) {
            let row = buffer.data.advanced(by: y * buffer.rowBytes)
            if byteProcessing {
                let pixels = row.assumingMemoryBound(to: UInt8.self)
                for x in 0..<Int(buffer.width) {
                    let offset = x * 4
                    let alpha = Int(pixels[offset + 3])
                    for channel in 0..<3 {
                        let unmatted = alpha == 0 ? 0 : Int((Double(pixels[offset + channel]) * 255 / Double(alpha)).rounded()) - (255 - alpha)
                        pixels[offset + channel] = UInt8(min(alpha, max(0, unmatted)))
                    }
                }
            } else {
                let pixels = row.assumingMemoryBound(to: Float.self)
                for x in 0..<Int(buffer.width) {
                    let offset = x * 4
                    let alpha = pixels[offset + 3]
                    for channel in 0..<3 {
                        pixels[offset + channel] = alpha > 0 ? max(0, pixels[offset + channel] / alpha - (1 - alpha)) : 0
                    }
                }
            }
        }
    }

    private static func drawSource(_ image: CGImage, orientation: Int, cropRect: CGRect, in buffer: vImage_Buffer,
                                   space: CGColorSpace, depth: Int, bitmapInfo: UInt32) throws {
        guard let context = CGContext(data: buffer.data, width: Int(buffer.width), height: Int(buffer.height),
                  bitsPerComponent: depth, bytesPerRow: buffer.rowBytes, space: space,
                  bitmapInfo: bitmapInfo) else { throw ResizeError.allocation }
        context.setBlendMode(.copy)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        // The selection uses a top-left origin; bitmap drawing uses the
        // bottom-left oriented image coordinates. Clip to the crop-size buffer.
        let orientedHeight = orientation >= 5 ? image.width : image.height
        context.translateBy(x: -cropRect.minX, y: -(CGFloat(orientedHeight) - cropRect.maxY))
        context.concatenate(orientationTransform(orientation, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.flush()
    }

    private static func orientationTransform(_ value: Int, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch value {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }

    private static func metadata(_ original: [String: Any], preserving: Bool,
                                 width: Int, height: Int, depth: Int, quality: Double, cropped: Bool) -> [String: Any] {
        var properties = preserving ? original : [:]
        properties.removeValue(forKey: kCGImageProperty8BIMDictionary as String)
        properties.removeValue(forKey: kCGImagePropertyFileSize as String)
        properties.removeValue(forKey: "ThumbnailImages")
        properties[kCGImagePropertyPixelWidth as String] = width
        properties[kCGImagePropertyPixelHeight as String] = height
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyDepth as String] = depth
        properties[kCGImagePropertyColorModel as String] = kCGImagePropertyColorModelRGB
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        if preserving {
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            if cropped {
                exif.removeValue(forKey: kCGImagePropertyExifSubjectArea as String)
                exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation as String)
            }
            exif[kCGImagePropertyExifPixelXDimension as String] = width
            exif[kCGImagePropertyExifPixelYDimension as String] = height
            properties[kCGImagePropertyExifDictionary as String] = exif
            var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff["ImageWidth"] = width
            tiff["ImageLength"] = height
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return properties
    }

    private static func updateMetadata(_ metadata: CGMutableImageMetadata, width: Int, height: Int, cropped: Bool) {
        let layerTags: Set<String> = ["LayerNames", "LayerCount", "LayerComps", "Layers", "LayerGroups", "TextLayers"]
        var removedPaths = [CFString]()
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String?
            let name = CGImageMetadataTagCopyName(tag) as String?
            if namespace == "http://ns.adobe.com/photoshop/1.0/", let name = name, layerTags.contains(name) {
                removedPaths.append(path)
            } else if cropped, let namespace = namespace, let name = name,
                      cropInvalidCoordinateTag(namespace: namespace, name: name) {
                removedPaths.append(path)
            }
            return true
        }
        for path in removedPaths { CGImageMetadataRemoveTagWithPath(metadata, nil, path) }
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelXDimension, width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelYDimension, height as CFNumber)
        for (path, value) in [("tiff:Orientation", 1), ("tiff:ImageWidth", width),
                              ("tiff:ImageLength", height), ("exif:PixelXDimension", width),
                              ("exif:PixelYDimension", height)] {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFNumber)
        }
        CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Thumbnails" as CFString)
    }

    private static func cropInvalidCoordinateTag(namespace: String, name: String) -> Bool {
        // Restrict removal to known coordinate annotations; retain unrelated
        // descriptions, capture/GPS/date fields, and other XMP schemas. Accept
        // current HTTPS and legacy HTTP namespace spellings.
        let namespace = namespace.hasPrefix("https://") ? "http://" + namespace.dropFirst(8) : namespace
        switch namespace {
        case "http://ns.adobe.com/exif/1.0/":
            return name == "SubjectArea" || name == "SubjectLocation"
        case "http://www.metadataworkinggroup.com/schemas/regions/":
            return name == "Regions"
        case "http://ns.microsoft.com/photo/1.2/":
            return name == "RegionInfo"
        case "http://iptc.org/std/Iptc4xmpExt/2008-02-29/":
            return name == "ImageRegion"
        default:
            return false
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ResizeError.unreadable(url.lastPathComponent) }
        return Int64(values.fileSize ?? 0)
    }

    private static func temporaryFile(in folder: URL) throws -> URL {
        let template = folder.appendingPathComponent(".resize-\(UUID().uuidString)-XXXXXX").path
        let path = strdup(template)
        guard let path = path else { throw ResizeError.allocation }
        defer { free(path) }
        let descriptor = mkstemp(path)
        guard descriptor >= 0 else { throw posixOutputError() }
        close(descriptor)
        return URL(fileURLWithPath: String(cString: path))
    }

    /// Publish without overwriting, including when several processes pick the
    /// same filename. RENAME_EXCL commits atomically on supported filesystems.
    private static func publish(_ staged: URL, in folder: URL, stem: String,
                                extension ext: String) throws -> URL {
        let name = stem.isEmpty ? "Image" : stem
        for counter in 1...100_000 {
            let candidateName = name + (counter == 1 ? "" : "-\(counter)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(candidateName)
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                chmod(candidate.path, mode_t(0o644))
                return candidate
            }
            let code = errno
            if code == EEXIST { continue }
            // Some removable/network filesystems lack exclusive rename. An
            // O_EXCL reservation still guarantees no existing file is replaced.
            if code == ENOTSUP || code == EINVAL {
                let descriptor = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
                if descriptor < 0 {
                    if errno == EEXIST { continue }
                    throw posixOutputError()
                }
                do {
                    try copyBytes(from: staged, toDescriptor: descriptor)
                    close(descriptor)
                    return candidate
                } catch {
                    close(descriptor)
                    unlink(candidate.path)
                    throw error
                }
            }
            throw ResizeError.output(String(cString: strerror(code)))
        }
        throw ResizeError.output("too many files share this name.")
    }

    private static func copyBytes(from source: URL, toDescriptor descriptor: Int32) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw ResizeError.unreadable(source.lastPathComponent) }
        defer { close(input) }
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        try buffer.withUnsafeMutableBytes { bytes in
            while true {
                let count = read(input, bytes.baseAddress, bytes.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixOutputError()
                }
                var written = 0
                while written < count {
                    let amount = write(descriptor, bytes.baseAddress!.advanced(by: written), count - written)
                    if amount < 0 {
                        if errno == EINTR { continue }
                        throw posixOutputError()
                    }
                    guard amount > 0 else { throw ResizeError.output("the output drive is full.") }
                    written += amount
                }
            }
        }
    }

    private static func posixOutputError() -> ResizeError {
        .output(String(cString: strerror(errno)))
    }
}
