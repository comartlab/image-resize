// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UniformTypeIdentifiers

// Lists paths only. Image decoding and validation belong to the export worker.
enum ImageDiscovery {
    static func isImagePath(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "jpe", "png", "tif", "tiff", "psd", "heic", "heif", "gif", "bmp", "webp", "avif", "ico", "icns", "jp2", "jpf", "jpx": return true
        case "": return false
        default: return UTType(filenameExtension: ext)?.conforms(to: .image) == true
        }
    }

    static func list(_ urls: [URL], recursive: Bool, excluding excluded: URL?,
                     cancelled: @escaping () -> Bool, publish: ([URL]) -> Void) -> [String] {
        var files: [URL] = [], errors: [String] = []
        let excludedPath = excluded?.resolvingSymlinksInPath().standardizedFileURL.path
        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        func flush() {
            guard !files.isEmpty else { return }
            publish(files); files.removeAll(keepingCapacity: true)
        }
        for url in urls {
            if cancelled() { break }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    files.append(url)
                    if files.count >= 256 { flush() }
                    continue
                }
                guard let enumerator = FileManager.default.enumerator(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: options, errorHandler: { failed, error in
                        errors.append("\(failed.path): \(error.localizedDescription)"); return !cancelled()
                    }) else {
                    errors.append("\(url.path): Could not list folder."); continue
                }
                for case let file as URL in enumerator {
                    if cancelled() { break }
                    do {
                        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                        if values.isDirectory == true {
                            if values.isSymbolicLink == true || (excludedPath != nil && file.resolvingSymlinksInPath().standardizedFileURL.path == excludedPath) {
                                enumerator.skipDescendants()
                            }
                        } else if values.isRegularFile == true && isImagePath(file) {
                            files.append(file)
                            if files.count >= 256 { flush() }
                        }
                    } catch { errors.append("\(file.path): \(error.localizedDescription)") }
                }
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !cancelled() { flush() }
        return errors
    }
}
