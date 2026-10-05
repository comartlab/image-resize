// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ImageIO
import QuickLookThumbnailing

enum ImagePreview {
    /// A larger, oriented source preview requested explicitly by the user.
    /// It is independent of output size, crop, watermark and fitting-file skips.
    static func editorImage(_ item: ImageItem, cancelled: () -> Bool) throws -> (ImageItem, NSImage) {
        let inspected = try ResizeEngine.inspect(item)
        guard !cancelled() else { throw CocoaError(.userCancelled) }
        if inspected.typeIdentifier == "com.adobe.photoshop-image" {
            let (current, image) = try ResizeEngine.sourcePreview(inspected, maxPixelDimension: 1600)
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            return (current, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        }
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ResizeError.decode(item.url.lastPathComponent)
        }
        guard !cancelled() else { throw CocoaError(.userCancelled) }
        return (inspected, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }

    private final class ThumbnailResult {
        private let lock = NSLock()
        private var value: CGImage?
        func set(_ image: CGImage?) { lock.lock(); value = image; lock.unlock() }
        func get() -> CGImage? { lock.lock(); defer { lock.unlock() }; return value }
    }

    // Cosmetic information only: no input acceptance or export decision depends
    // on this work. Full source validation remains in ResizeEngine.resize.
    static func load(_ item: ImageItem, cancelled: () -> Bool) -> (ImageItem?, NSImage?) {
        guard !cancelled() else { return (nil, nil) }
        var metadata: ImageItem?, thumbnail: CGImage?
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, options as CFDictionary) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
               let type = CGImageSourceGetType(source) {
                let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
                let width = rotated ? pixelHeight.intValue : pixelWidth.intValue
                let height = rotated ? pixelWidth.intValue : pixelHeight.intValue
                let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if width > 0 && height > 0 {
                    metadata = ImageItem(id: item.id, url: item.url, width: width, height: height,
                                         fileBytes: Int64(bytes), typeIdentifier: type as String)
                }
            }
            guard !cancelled() else { return (nil, nil) }
            // Never decode a full TIFF/PSD just to obtain a small list thumbnail.
            let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCache: false]
            thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        }
        guard !cancelled() else { return (nil, nil) }
        if thumbnail == nil {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: NSSize(width: 96, height: 96),
                                                       scale: 1, representationTypes: .thumbnail)
            let result = ThumbnailResult(), completed = DispatchSemaphore(value: 0)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                result.set(representation?.cgImage); completed.signal()
            }
            // This runs on the serial utility worker, never the main/export thread.
            while completed.wait(timeout: .now() + 0.1) == .timedOut {
                if cancelled() {
                    QLThumbnailGenerator.shared.cancel(request); return (nil, nil)
                }
            }
            thumbnail = result.get()
        }
        guard !cancelled() else { return (nil, nil) }
        return (metadata, thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
    }
}
