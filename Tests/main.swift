// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import ImageIO
import Foundation
import CryptoKit

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message) }
}

func requireThrows(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure(message)
}

func requireCancellation(_ message: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch is CancellationError { return }
    catch { throw TestFailure("\(message): returned \(error) instead of CancellationError") }
    throw TestFailure(message)
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/test-work", isDirectory: true)
let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
let output = work.appendingPathComponent("output", isDirectory: true)
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("PASS \(name)")
    } catch {
        failed += 1
        print("FAIL \(name): \(error)")
    }
}

func bitmap(width: Int = 80, height: Int = 40, transparent: Bool = false, p3: Bool = false) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    // Row-major pixels: red/green top row, blue/yellow bottom row. The asymmetric
    // dimensions and colors make all eight EXIF orientation transforms distinct.
    let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    for y in 0..<height {
        for x in 0..<width {
            let index = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
            let pixel = (y * width + x) * 4
            for c in 0..<4 { bytes[pixel + c] = colors[index][c] }
            if transparent && x < width / 2 { bytes[pixel + 3] = 0 }
        }
    }
    let colorSpace = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
    let data = Data(bytes) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: colorSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else {
        throw TestFailure("Could not create fixture bitmap")
    }
    return image
}

@discardableResult
func fixture(_ name: String, type: String = "public.png", image: CGImage? = nil,
             properties: [CFString: Any] = [:], frames: Int = 1) throws -> URL {
    let url = work.appendingPathComponent(name)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil) else {
        throw TestFailure("ImageIO cannot encode fixture type \(type)")
    }
    let sourceImage = try image ?? bitmap()
    for _ in 0..<frames { CGImageDestinationAddImage(destination, sourceImage, properties as CFDictionary) }
    try require(CGImageDestinationFinalize(destination), "Could not finish fixture \(name)")
    return url
}

func source(_ url: URL) throws -> CGImageSource {
    guard let result = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw TestFailure("Cannot decode \(url.lastPathComponent)")
    }
    return result
}

func properties(_ url: URL) throws -> NSDictionary {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(try source(url), 0, nil) else {
        throw TestFailure("Cannot read output properties")
    }
    return properties as NSDictionary
}

func outputURL(_ result: ResizeResult) throws -> URL {
    guard let url = result.output else { throw TestFailure("Resize returned no output: \(result.message)") }
    try require(fileManager.fileExists(atPath: url.path), "Output does not exist")
    return url
}

func requireSkipped(_ result: ResizeResult, width: Int, height: Int) throws {
    try require(result.skipped && result.output == nil && result.outputBytes == 0,
                "Unchanged target did not return a skip without an output")
    try require(result.width == width && result.height == height, "Skip changed reported image dimensions")
}

func directorySnapshot(_ url: URL) throws -> [String: Data] {
    var snapshot = [String: Data]()
    for file in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
        snapshot[file.lastPathComponent] = Data(SHA256.hash(data: try Data(contentsOf: file)))
    }
    return snapshot
}

func assertDimensions(_ url: URL, _ width: Int, _ height: Int) throws {
    guard let image = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else {
        throw TestFailure("ImageIO could not decode output pixels")
    }
    try require(image.width == width && image.height == height,
                "Expected \(width)×\(height), got \(image.width)×\(image.height)")
}

func pixels(_ url: URL) throws -> (Int, Int, [UInt8]) {
    guard let image = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else {
        throw TestFailure("Could not decode output pixels")
    }
    return try pixels(image)
}

func pixels(_ image: CGImage) throws -> (Int, Int, [UInt8]) {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    try data.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure("Could not make pixel readback context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, data)
}

func color(_ pixels: (Int, Int, [UInt8]), x: Double, y: Double) -> [UInt8] {
    let px = min(pixels.0 - 1, Int(Double(pixels.0) * x))
    let py = min(pixels.1 - 1, Int(Double(pixels.1) * y))
    let start = (py * pixels.0 + px) * 4
    return Array(pixels.2[start..<(start + 4)])
}

func requireColor(_ actual: [UInt8], _ expected: [UInt8], _ message: String, tolerance: Int = 20) throws {
    try require(zip(actual, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= tolerance },
                "\(message): expected \(expected), got \(actual)")
}

func solidBitmap(width: Int, height: Int, white: CGFloat, p3: Bool = false) throws -> CGImage {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw TestFailure("Could not create solid fixture")
    }
    context.setFillColor(red: white, green: white, blue: white, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func texturedBitmap(width: Int = 1200, height: Int = 800) throws -> CGImage {
    // Deterministic gradients and fine texture exercise photographic JPEG
    // compression without depending on an external or private photograph.
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var state: UInt32 = 0x71329acd
    for y in 0..<height {
        for x in 0..<width {
            state = state &* 1664525 &+ 1013904223
            let noise = Double(Int(state >> 24) - 128) * 0.22
            let wave = sin(Double(x) / 53) * 18 + cos(Double(y) / 37) * 12
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(clamping: Int(80 + Double(x) / Double(width) * 125 + wave + noise))
            bytes[offset + 1] = UInt8(clamping: Int(55 + Double(y) / Double(height) * 135 + wave * 0.4 + noise))
            bytes[offset + 2] = UInt8(clamping: Int(170 - Double(x) / Double(width) * 80 + wave * 0.7 + noise))
        }
    }
    guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent) else { throw TestFailure("Cannot create textured compression fixture") }
    return image
}

func webEncodingCandidates(_ image: CGImage, quality: Double) throws -> [(String, Data)] {
    // Independent native encodes at the same geometry, color space and quality.
    // A fully opaque RGB buffer avoids an unnecessary PNG alpha channel.
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let rgb = context.makeImage() else { throw TestFailure("Cannot render web candidate reference") }
    var results = [(String, Data)]()
    for (type, progressive) in [("public.jpeg", false), ("public.jpeg", true), ("public.png", false)] {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil) else {
            throw TestFailure("Cannot encode native web candidate")
        }
        var props: [CFString: Any] = [kCGImagePropertyPixelWidth: rgb.width, kCGImagePropertyPixelHeight: rgb.height,
                                     kCGImagePropertyOrientation: 1, kCGImagePropertyDepth: 8,
                                     kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
                                     kCGImageDestinationLossyCompressionQuality: quality,
                                     kCGImageDestinationEmbedThumbnail: false]
        if type == "public.jpeg" { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: progressive] }
        else { props[kCGImagePropertyPNGCompressionFilter] = 0xf8 }
        CGImageDestinationAddImage(destination, rgb, props as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Could not finish native web candidate")
        results.append((type, bytes as Data))
    }
    return results
}

func changedPixels(_ first: (Int, Int, [UInt8]), _ second: (Int, Int, [UInt8]), threshold: Int = 2) throws -> [UInt8] {
    try require(first.0 == second.0 && first.1 == second.1, "Cannot compare different image sizes")
    var mask = [UInt8](repeating: 0, count: first.0 * first.1)
    for pixel in 0..<mask.count {
        for channel in 0..<4 {
            if abs(Int(first.2[pixel * 4 + channel]) - Int(second.2[pixel * 4 + channel])) > threshold {
                mask[pixel] = 1
                break
            }
        }
    }
    return mask
}

struct PixelComponent {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    let count: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

func components(mask: [UInt8], width: Int, height: Int) -> [PixelComponent] {
    var visited = [UInt8](repeating: 0, count: mask.count)
    var result = [PixelComponent]()
    for index in 0..<mask.count where mask[index] != 0 && visited[index] == 0 {
        var queue = [index]
        visited[index] = 1
        var cursor = 0
        var minX = index % width
        var maxX = minX
        var minY = index / width
        var maxY = minY
        while cursor < queue.count {
            let pixel = queue[cursor]
            cursor += 1
            let x = pixel % width
            let y = pixel / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nextX = x + dx
                    let nextY = y + dy
                    if nextX >= 0 && nextX < width && nextY >= 0 && nextY < height {
                        let next = nextY * width + nextX
                        if mask[next] != 0 && visited[next] == 0 {
                            visited[next] = 1
                            queue.append(next)
                        }
                    }
                }
            }
        }
        result.append(PixelComponent(minX: minX, minY: minY, maxX: maxX, maxY: maxY, count: queue.count))
    }
    return result
}

func watermarked(_ url: URL, text: String = "SAMPLE", longestEdge: Int = 1600,
                 format: OutputFormat = .png, strength: Double = 0.25) throws -> ResizeResult {
    let item = try ResizeEngine.inspect(url)
    var settings = ResizeSettings()
    // Rendering regressions deliberately change a dimension, because equal
    // target dimensions skip every output operation, including watermark drawing.
    settings.width = min(longestEdge, max(item.width, item.height) - 1)
    settings.format = format
    settings.watermarkEnabled = true
    settings.watermarkText = text
    settings.watermarkStrength = strength
    return try ResizeEngine.resize(item, to: output, settings: settings)
}

func plainReduction(_ url: URL, longestEdge: Int = 1600) throws -> URL {
    let item = try ResizeEngine.inspect(url)
    var settings = ResizeSettings()
    settings.width = min(longestEdge, max(item.width, item.height) - 1)
    settings.format = .png
    return try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
}

test("Large uninspected queues accept nonexistent paths without delaying metadata work") {
    let queue = ImageQueue()
    let folder = work.appendingPathComponent("not-created-\(UUID().uuidString)")
    let urls = (0..<20_000).map { folder.appendingPathComponent("image-\($0).png") }
    let start = ProcessInfo.processInfo.systemUptime
    let added = queue.append(urls)
    let enqueueTime = ProcessInfo.processInfo.systemUptime - start
    try require(added == 0..<20_000 && queue.items.count == 20_000, "Queue rejected files before background inspection")
    try require(queue.inspectedCount == 0 && queue.totalBytes == 0 && queue.items.allSatisfy { !$0.isInspected },
                "Enqueuing read image metadata or claimed unknown sizes")
    try require(queue.items.map(\.url) == urls, "Enqueue changed file order or membership")
    try require(Set(queue.items.map(\.id)).count == urls.count, "Queued files share identities")
    let batch = queue.items
    let streamed = ImageQueue()
    let streamStart = ProcessInfo.processInfo.systemUptime
    for start in stride(from: 0, to: urls.count, by: 256) {
        streamed.append(Array(urls[start..<min(start + 256, urls.count)]))
    }
    let streamTime = ProcessInfo.processInfo.systemUptime - streamStart
    try require(streamed.items.map(\.url) == urls && streamed.inspectedCount == 0,
                "Streamed discovery batches lost pending queue membership")
    let duplicate = folder.appendingPathComponent("unused/../image-0.png")
    try require(queue.append([urls[0], duplicate]) == 20_000..<20_000, "Lexically equivalent paths were queued twice")
    let metadataStart = ProcessInfo.processInfo.systemUptime
    for item in batch {
        let ready = ImageItem(id: item.id, url: item.url, width: 123, height: 77, fileBytes: 100, typeIdentifier: "public.png")
        try require(queue.update(ready) == queue.index(of: item.id), "Metadata update lost stable queue identity")
    }
    let metadataTime = ProcessInfo.processInfo.systemUptime - metadataStart
    try require(queue.inspectedCount == urls.count && queue.totalBytes == 2_000_000, "Large queue metadata counters are incorrect")
    try require(batch.allSatisfy { !$0.isInspected } && batch.map(\.id) == queue.items.map(\.id),
                "Background metadata mutated the active batch snapshot")
    print(String(format: "Queue20k: enqueue %.3f s; batches256 %.3f s; metadata updates %.3f s; zero input reads while enqueueing", enqueueTime, streamTime, metadataTime))
}

test("Folder discovery publishes multiple batches without validating corrupt image pixels") {
    let folder = work.appendingPathComponent("discovery-batches")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let expected = (0..<600).map { folder.appendingPathComponent("unreadable-\($0).jpg") }
    for url in expected { try Data().write(to: url) }
    try Data("sidecar".utf8).write(to: folder.appendingPathComponent("notes.txt"))
    let before = try directorySnapshot(folder)
    let queue = ImageQueue()
    var batches = [[URL]]()
    let start = ProcessInfo.processInfo.systemUptime
    let errors = ImageDiscovery.list([folder], recursive: false, excluding: nil, cancelled: { false }, publish: { urls in
        batches.append(urls)
        queue.append(urls)
    })
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    try require(errors.isEmpty && batches.count >= 3 && batches.allSatisfy { !$0.isEmpty && $0.count <= 256 },
                "Discovery waited for image validation or failed to stream bounded path batches")
    try require(queue.items.count == 600 && Set(queue.items.map(\.url)) == Set(expected),
                "Streamed discovery omitted, duplicated or added input paths")
    try require(queue.inspectedCount == 0 && queue.items.allSatisfy { !$0.isInspected },
                "Folder discovery decoded or rejected corrupt image-named files")
    try require(try directorySnapshot(folder) == before, "Discovery changed input paths or bytes")
    print(String(format: "Discovery600 empty JPEGs: %.3f s; %d path batches", elapsed, batches.count))
}

test("Folder discovery respects Subfolders and excludes the chosen nested output folder") {
    let folder = work.appendingPathComponent("discovery-recursion")
    let nested = folder.appendingPathComponent("nested")
    let deep = nested.appendingPathComponent("deep")
    let excluded = nested.appendingPathComponent("output")
    for directory in [folder, nested, deep, excluded] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let top = [folder.appendingPathComponent("top.JPEG"), folder.appendingPathComponent("layered.psd")]
    let descendants = [nested.appendingPathComponent("nested.tiff"), deep.appendingPathComponent("deep.png")]
    for url in top + descendants + [excluded.appendingPathComponent("previous.jpg"), folder.appendingPathComponent(".hidden.jpg")] {
        try Data("not decoded while listing".utf8).write(to: url)
    }
    try Data().write(to: folder.appendingPathComponent("sidecar.xmp"))
    func discovered(recursive: Bool) throws -> [URL] {
        var paths = [URL]()
        let errors = ImageDiscovery.list([folder], recursive: recursive, excluding: excluded, cancelled: { false }, publish: { paths += $0 })
        try require(errors.isEmpty, "Discovery failed to enumerate its owned test folder")
        return paths
    }
    try require(Set(try discovered(recursive: false)) == Set(top), "Subfolders off included descendants or omitted top-level image names")
    let captured = try discovered(recursive: true)
    try require(Set(captured) == Set(top + descendants), "Recursive discovery entered the output folder or omitted source paths")
    let sourceBytes = try (top + descendants).map { try Data(contentsOf: $0) }
    // Export starts only after discovery has completed. New output filenames
    // cannot enter this captured batch, and a later discovery excludes them too.
    for index in 0..<300 { try Data().write(to: excluded.appendingPathComponent("new-output-\(index).jpg")) }
    try require(Set(captured) == Set(top + descendants) && Set(try discovered(recursive: true)) == Set(captured),
                "Output creation changed captured source membership or fed outputs into a later import")
    try require(try (top + descendants).map { try Data(contentsOf: $0) } == sourceBytes,
                "Listing/output creation modified source data")
}

test("Cancellation during discovery stops publishing the remaining paths") {
    let folder = work.appendingPathComponent("discovery-cancellation")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<700 { try Data().write(to: folder.appendingPathComponent("source-\(index).jpg")) }
    var cancelled = false
    var paths = [URL]()
    var batches = 0
    let errors = ImageDiscovery.list([folder], recursive: true, excluding: nil, cancelled: { cancelled }, publish: { urls in
        paths += urls
        batches += 1
        cancelled = true
    })
    try require(errors.isEmpty && batches == 1 && paths.count == 256 && Set(paths).count == 256,
                "Cancelled discovery continued publishing or lost the completed path batch")
    var unexpectedPublish = false
    _ = ImageDiscovery.list([folder], recursive: true, excluding: nil, cancelled: { true }, publish: { _ in unexpectedPublish = true })
    try require(!unexpectedPublish, "Already-cancelled discovery published paths")
    try require(try fileManager.contentsOfDirectory(atPath: folder.path).count == 700, "Discovery cancellation changed source membership")
}

test("Queue metadata updates preserve identities, reject wrong sources and maintain cached totals") {
    let queue = ImageQueue()
    let urls = (0..<3).map { work.appendingPathComponent("pending-\($0).png") }
    queue.append(urls)
    let pending = queue.items[1]
    let first = ImageItem(id: pending.id, url: pending.url, width: 80, height: 40, fileBytes: 1234, typeIdentifier: "public.png")
    try require(queue.update(first) == 1 && queue.inspectedCount == 1 && queue.totalBytes == 1234, "First metadata completion is incorrect")
    let refreshed = ImageItem(id: pending.id, url: pending.url, width: 160, height: 90, fileBytes: 4321, typeIdentifier: "public.png")
    try require(queue.update(refreshed) == 1 && queue.inspectedCount == 1 && queue.totalBytes == 4321, "Repeated metadata double-counted the file")
    let wrongURL = ImageItem(id: pending.id, url: urls[0], width: 160, height: 90, fileBytes: 99, typeIdentifier: "public.png")
    try require(queue.update(wrongURL) == nil, "Metadata was attached to a different source URL")
    let wrongID = ImageItem(url: pending.url, width: 160, height: 90, fileBytes: 99, typeIdentifier: "public.png")
    try require(queue.update(wrongID) == nil, "Metadata was attached by path instead of queue identity")
    try require(queue.totalBytes == 4321 && queue.inspectedCount == 1 && queue.items[1].id == pending.id,
                "Rejected metadata changed queue counters or identity")
    try require(queue.update(ImageItem.queued(pending.url, id: pending.id)) == 1 && queue.inspectedCount == 0 && queue.totalBytes == 0,
                "Clearing known metadata left stale queue totals")
}

test("Removed and cleared queue entries reject stale completions after reimport") {
    let queue = ImageQueue()
    let urls = (0..<5).map { work.appendingPathComponent("removable-\($0).png") }
    queue.append(urls)
    let before = queue.items
    let removed = queue.remove(at: IndexSet([1, 3, 99]))
    try require(removed == [before[1].id, before[3].id], "Removal returned the wrong identities")
    try require(queue.items.map(\.id) == [before[0].id, before[2].id, before[4].id] && queue.index(of: before[2].id) == 1,
                "Removal corrupted surviving order or UUID lookup")
    queue.append([urls[1]])
    let replacement = queue.items.last!
    try require(replacement.id != before[1].id, "Reimport reused the removed entry's identity")
    let stale = ImageItem(id: before[1].id, url: urls[1], width: 80, height: 40, fileBytes: 999, typeIdentifier: "public.png")
    try require(queue.update(stale) == nil && !replacement.isInspected, "Old background completion populated a reimported file")
    let live = ImageItem(id: replacement.id, url: replacement.url, width: 80, height: 40, fileBytes: 321, typeIdentifier: "public.png")
    try require(queue.update(live) == 3 && queue.totalBytes == 321, "New live completion was rejected")
    queue.clear()
    try require(queue.items.isEmpty && queue.inspectedCount == 0 && queue.totalBytes == 0 && queue.index(of: replacement.id) == nil,
                "Clear left stale queue state")
    queue.append(urls)
    try require(queue.update(live) == nil && queue.totalBytes == 0 && queue.inspectedCount == 0,
                "Completion from before Clear populated the new import")
    try require(Set(queue.items.map(\.id)).isDisjoint(with: Set(before.map(\.id))), "Clear/reimport reused old identities")
}

test("Pending and ready batch snapshots remain stable while queue membership changes") {
    let queue = ImageQueue()
    let urls = (0..<4).map { work.appendingPathComponent("snapshot-\($0).png") }
    queue.append(Array(urls.prefix(3)))
    let first = queue.items[0]
    _ = queue.update(ImageItem(id: first.id, url: first.url, width: 80, height: 40, fileBytes: 100, typeIdentifier: "public.png"))
    let batch = queue.items
    let second = queue.items[1]
    _ = queue.update(ImageItem(id: second.id, url: second.url, width: 160, height: 90, fileBytes: 200, typeIdentifier: "public.png"))
    queue.append([urls[3]])
    queue.remove(at: IndexSet(integer: 0))
    try require(batch.count == 3 && batch.map(\.url) == Array(urls.prefix(3)), "Active snapshot lost or gained queued files")
    try require(batch[0].isInspected && !batch[1].isInspected && !batch[2].isInspected, "Later metadata mutated captured batch state")
    try require(queue.items.count == 3 && queue.totalBytes == 200 && queue.inspectedCount == 1,
                "Queue did not retain independent membership and metadata counters")
}

test("Cached queue byte totals recover correctly after overflow-sized metadata is removed") {
    let queue = ImageQueue()
    queue.append((0..<3).map { work.appendingPathComponent("large-total-\($0).png") })
    for (index, bytes) in [Int64.max, Int64.max, 7].enumerated() {
        let pending = queue.items[index]
        _ = queue.update(ImageItem(id: pending.id, url: pending.url, width: 1, height: 1, fileBytes: bytes, typeIdentifier: "public.png"))
    }
    try require(queue.totalBytes == Int64.max && queue.inspectedCount == 3, "Huge totals overflowed or limited queue membership")
    queue.remove(at: IndexSet([0, 1]))
    try require(queue.totalBytes == 7 && queue.inspectedCount == 1, "Saturated totals did not recover after removal")
}

test("Uninspected sources resize immediately and report fresh metadata with stable queue identities") {
    let url = try fixture("queued-processing.png", image: bitmap(width: 120, height: 80))
    let queue = ImageQueue()
    queue.append([url])
    let pending = queue.items[0]
    var settings = ResizeSettings()
    settings.width = 60
    var callbacks = [ImageItem]()
    let before = try directorySnapshot(output)
    let result = try ResizeEngine.resize(pending, to: output, settings: settings, onInspect: { inspected in
        callbacks.append(inspected)
        _ = queue.update(inspected)
    })
    try require(callbacks.count == 1 && callbacks[0].id == pending.id && callbacks[0].width == 120 && callbacks[0].height == 80,
                "Processing inspection lost queue identity or reported stale dimensions")
    try require(queue.items[0].isInspected && queue.inspectedCount == 1 && queue.totalBytes == Int64(try Data(contentsOf: url).count),
                "Processing did not enrich the pending queue entry")
    try assertDimensions(outputURL(result), 60, 40)
    try require(try directorySnapshot(output).count == before.count + 1, "Queued source did not produce one resized output")
    settings.width = 1600
    var skippedCallbacks = 0
    let skipped = try ResizeEngine.resize(ImageItem.queued(url), to: output, settings: settings, onInspect: { _ in skippedCallbacks += 1 })
    try requireSkipped(skipped, width: 120, height: 80)
    try require(skippedCallbacks == 1, "Skipped pending image never reported inspected metadata")
    let refreshed = try ResizeEngine.inspect(pending)
    try require(refreshed.id == pending.id && refreshed.isInspected, "Background inspection replaced the queue identity")
}

test("Invalid queued sources fail during processing without output or premature metadata") {
    let url = work.appendingPathComponent("assumed-valid.png")
    try Data("not an image".utf8).write(to: url)
    let queue = ImageQueue()
    queue.append([url])
    let before = try directorySnapshot(output)
    var callbacks = 0
    try requireThrows("Corrupt assumed-valid input was silently accepted during processing") {
        _ = try ResizeEngine.resize(queue.items[0], to: output, settings: ResizeSettings(), onInspect: { _ in callbacks += 1 })
    }
    try require(callbacks == 0 && queue.inspectedCount == 0 && !queue.items[0].isInspected,
                "Failed processing claimed successful source inspection")
    try require(try directorySnapshot(output) == before, "Failed queued input wrote output files")
}

test("Aspect-preserving dimensions for every resize mode") {
    var settings = ResizeSettings()
    settings.mode = .longestEdge
    settings.width = 1600
    let landscape = try ResizeEngine.targetSize(width: 4000, height: 3000, settings: settings)
    let portrait = try ResizeEngine.targetSize(width: 3000, height: 4000, settings: settings)
    try require(landscape.width == 1600 && landscape.height == 1200, "Wrong landscape longest edge")
    try require(portrait.width == 1200 && portrait.height == 1600, "Wrong portrait longest edge")
    settings.mode = .fit
    settings.width = 1000
    settings.height = 600
    let fit = try ResizeEngine.targetSize(width: 4000, height: 2000, settings: settings)
    try require(fit.width == 1000 && fit.height == 500, "Fit did not respect the bounding box")
    settings.mode = .width
    settings.width = 900
    let width = try ResizeEngine.targetSize(width: 3000, height: 2000, settings: settings)
    try require(width.width == 900 && width.height == 600, "Wrong width-based dimensions")
    settings.mode = .height
    settings.height = 600
    let height = try ResizeEngine.targetSize(width: 3000, height: 2000, settings: settings)
    try require(height.width == 900 && height.height == 600, "Wrong height-based dimensions")
    settings.mode = .percent
    settings.percent = 25
    let percent = try ResizeEngine.targetSize(width: 3200, height: 2400, settings: settings)
    try require(percent.width == 800 && percent.height == 600, "Wrong percent dimensions")
}

test("Every resize mode enlarges small images proportionally; extreme ratios stay nonzero") {
    let cases: [(ResizeMode, Int, Int)] = [(.longestEdge, 200, 100), (.fit, 200, 100),
        (.width, 200, 100), (.height, 240, 120), (.percent, 120, 60)]
    for (mode, width, height) in cases {
        var settings = ResizeSettings()
        settings.mode = mode
        settings.width = 200
        settings.height = 120
        settings.percent = 150
        let disabled = try ResizeEngine.targetSize(width: 80, height: 40, settings: settings)
        try require(disabled.width == 80 && disabled.height == 40, "Default settings enlarged \(mode) without opt-in")
        settings.allowUpscaling = true
        let size = try ResizeEngine.targetSize(width: 80, height: 40, settings: settings)
        try require(size.width == width && size.height == height, "\(mode) failed to enlarge proportionally")
    }
    var settings = ResizeSettings()
    settings.width = 2
    let narrow = try ResizeEngine.targetSize(width: 3, height: 10000, settings: settings)
    try require(narrow.width == 1 && narrow.height == 2, "Extreme aspect ratio produced an invalid size")
}

test("Every enlargement mode writes proportional pixels without replacing sources or existing outputs") {
    let input = try fixture("upscale-modes/image.png")
    let original = try Data(contentsOf: input)
    let folder = input.deletingLastPathComponent()
    let occupied = folder.appendingPathComponent("image-2.png")
    let sentinel = Data("An existing output must not be replaced".utf8)
    try sentinel.write(to: occupied)
    let cases: [(ResizeMode, Int, Int)] = [(.longestEdge, 200, 100), (.fit, 200, 100),
        (.width, 200, 100), (.height, 240, 120), (.percent, 120, 60)]
    let expected: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    var written = Set<URL>()
    for (mode, width, height) in cases {
        var settings = ResizeSettings(); settings.mode = mode; settings.width = 200; settings.height = 120
        settings.allowUpscaling = true
        settings.percent = 150; settings.format = .png
        let result = try ResizeEngine.resize(ImageItem.queued(input), to: folder, settings: settings)
        let url = try outputURL(result)
        try require(!result.skipped && result.width == width && result.height == height &&
                    url != input && url != occupied && written.insert(url).inserted,
                    "\(mode) skipped enlargement or replaced another file")
        try assertDimensions(url, width, height)
        let actual = try pixels(url)
        for (index, probe) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)].enumerated() {
            try requireColor(color(actual, x: probe.0, y: probe.1), expected[index],
                             "\(mode) enlargement changed an interior color", tolerance: 3)
        }
    }
    try require(try Data(contentsOf: input) == original && Data(contentsOf: occupied) == sentinel,
                "Enlargement changed source or occupied output bytes")
    try require(try fileManager.contentsOfDirectory(atPath: folder.path).count == 7,
                "Enlargement left temporary files or lost an output")
}

test("Invalid dimensions and percentages fail before encoding") {
    var settings = ResizeSettings()
    settings.width = 0
    try requireThrows("Accepted zero width") { _ = try ResizeEngine.targetSize(width: 80, height: 40, settings: settings) }
    settings.width = 20
    settings.mode = .fit
    settings.height = -2
    try requireThrows("Accepted negative height") { _ = try ResizeEngine.targetSize(width: 80, height: 40, settings: settings) }
    settings.mode = .percent
    for percent in [0.0, -1.0, .nan, .infinity, -.infinity] {
        settings.percent = percent
        try requireThrows("Accepted invalid percent \(percent)") { _ = try ResizeEngine.targetSize(width: 80, height: 40, settings: settings) }
    }
}

test("Large pixel bounds have no arbitrary cap and remain safe near Int.max") {
    var settings = ResizeSettings()
    settings.allowUpscaling = true
    settings.width = 1_000_000
    settings.height = 1_000_000
    for mode in [ResizeMode.longestEdge, .fit, .width, .height] {
        settings.mode = mode
        let enlarged = try ResizeEngine.targetSize(width: 300_000, height: 250_000, settings: settings)
        let expected = mode == .height ? (1_200_000, 1_000_000) : (1_000_000, 833_333)
        try require(enlarged.width == expected.0 && enlarged.height == expected.1,
                    "\(mode) imposed an arbitrary large-image size cap")
    }
    settings.mode = .longestEdge
    let resized = try ResizeEngine.targetSize(width: 2_000_000, height: 1_000_000, settings: settings)
    try require(resized.width == 1_000_000 && resized.height == 500_000, "Large target dimensions were capped")
    settings.width = Int.max
    settings.height = Int.max
    for mode in [ResizeMode.longestEdge, .fit, .width] {
        settings.mode = mode
        let unchanged = try ResizeEngine.targetSize(width: Int.max, height: Int.max / 2, settings: settings)
        try require(unchanged.width == Int.max && unchanged.height == Int.max / 2,
                    "\(mode) changed dimensions when the target equalled the source")
    }
    settings.mode = .height
    settings.allowUpscaling = false
    let disabled = try ResizeEngine.targetSize(width: Int.max, height: Int.max / 2, settings: settings)
    try require(disabled.width == Int.max && disabled.height == Int.max / 2,
                "Disabled enlargement overflowed instead of leaving a smaller image alone")
    settings.allowUpscaling = true
    try requireThrows("An unrepresentable enlarged width overflowed instead of failing") {
        _ = try ResizeEngine.targetSize(width: Int.max, height: Int.max / 2, settings: settings)
    }
    settings.mode = .longestEdge
    for bound in [Int.max - 1, Int.max - 4096] {
        settings.width = bound
        let nearMaximum = try ResizeEngine.targetSize(width: Int.max, height: Int.max / 2, settings: settings)
        try require(nearMaximum.width > 0 && nearMaximum.height > 0 && nearMaximum.width <= settings.width,
                    "Near-Int.max target overflowed or exceeded its bound")
        try require(nearMaximum.height <= Int.max / 2, "Near-Int.max target enlarged height")
    }
    settings.width = 1
    let tiny = try ResizeEngine.targetSize(width: Int.max, height: Int.max - 1, settings: settings)
    try require(tiny.width == 1 && tiny.height == 1, "Extreme reduction overflowed")
}

test("Native JPEG, PNG, TIFF and HEIC encode and decode") {
    let url = try fixture("formats.png")
    let item = try ResizeEngine.inspect(url)
    let formats: [(OutputFormat, String)] = [(.jpeg, "public.jpeg"), (.png, "public.png"), (.tiff, "public.tiff"), (.heic, "public.heic")]
    for (format, type) in formats {
        var settings = ResizeSettings()
        settings.width = 40
        settings.format = format
        let result = try ResizeEngine.resize(item, to: output, settings: settings)
        let url = try outputURL(result)
        try assertDimensions(url, 40, 20)
        try require(CGImageSourceGetType(try source(url)) as String? == type, "Wrong encoded type for \(format)")
        try require(result.width == 40 && result.height == 20 && result.outputBytes > 0 && !result.skipped,
                    "Resize result did not report encoded dimensions/size")
    }
}

test("All eight EXIF orientations normalize dimensions and pixel positions") {
    // Expected top-left, top-right, bottom-left, bottom-right quadrant indices.
    let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                    [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
    let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    let probes = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
    for orientation in 1...8 {
        let url = try fixture("orientation-\(orientation).tiff", type: "public.tiff",
                              properties: [kCGImagePropertyOrientation: orientation])
        let item = try ResizeEngine.inspect(url)
        let rotated = orientation >= 5
        try require(item.width == (rotated ? 40 : 80) && item.height == (rotated ? 80 : 40),
                    "inspect ignored orientation \(orientation)")
        var settings = ResizeSettings()
        settings.width = 40
        settings.format = .png
        let result = try ResizeEngine.resize(item, to: output, settings: settings)
        let resized = try outputURL(result)
        try assertDimensions(resized, rotated ? 20 : 40, rotated ? 40 : 20)
        let properties = try properties(resized)
        let outputOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        try require(outputOrientation == 1, "Output retained a non-normalized EXIF orientation")
        let rgba = try pixels(resized)
        for (index, probe) in probes.enumerated() {
            try requireColor(color(rgba, x: probe.0, y: probe.1), colors[expected[orientation - 1][index]],
                             "Wrong quadrant for EXIF orientation \(orientation)")
        }
    }
}

test("PNG alpha survives; JPEG composites transparent areas onto white") {
    let url = try fixture("transparent.png", image: bitmap(transparent: true))
    let item = try ResizeEngine.inspect(url)
    var settings = ResizeSettings()
    settings.width = 40
    settings.format = .png
    let png = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
    let pngPixels = try pixels(png)
    try require(color(pngPixels, x: 0.2, y: 0.2)[3] == 0, "PNG discarded transparency")
    try require(color(pngPixels, x: 0.8, y: 0.2)[3] == 255, "PNG changed opaque pixels' alpha")
    settings.format = .jpeg
    let jpeg = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
    try requireColor(color(try pixels(jpeg), x: 0.2, y: 0.2), [255, 255, 255, 255], "JPEG transparency matte")
}

test("Large reductions antialias fine repeating detail") {
    let dimension = 128
    var bytes = [UInt8](repeating: 255, count: dimension * dimension * 4)
    for y in 0..<dimension {
        for x in 0..<dimension {
            let value: UInt8 = (x + y).isMultiple(of: 2) ? 0 : 255
            let offset = (y * dimension + x) * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let checkerboard = CGImage(width: dimension, height: dimension, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: dimension * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)!
    let url = try fixture("checkerboard.png", image: checkerboard)
    var settings = ResizeSettings()
    settings.width = 16
    settings.format = .png
    let resized = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(url), to: output, settings: settings))
    let rgba = try pixels(resized)
    for y in [0.25, 0.5, 0.75] {
        for x in [0.25, 0.5, 0.75] {
            let pixel = color(rgba, x: x, y: y)
            try require(pixel.prefix(3).allSatisfy { $0 > 80 && $0 < 220 },
                        "Fine detail aliased to solid black/white: \(pixel)")
        }
    }
}

test("Metadata choice preserves or strips GPS/EXIF and retains color profile") {
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N",
                              kCGImagePropertyGPSLongitude: 71.2, kCGImagePropertyGPSLongitudeRef: "W"]
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:04 12:00:00"]
    let url = try fixture("metadata.jpg", type: "public.jpeg", image: bitmap(p3: true),
                          properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif])
    let original = try properties(url)
    try require(original[kCGImagePropertyGPSDictionary] != nil, "Fixture did not contain GPS metadata")
    try require(original[kCGImagePropertyProfileName] != nil, "Fixture did not contain a color profile")
    let item = try ResizeEngine.inspect(url)
    var settings = ResizeSettings()
    settings.width = 40
    settings.format = .jpeg
    settings.preserveMetadata = true
    let retained = try properties(outputURL(ResizeEngine.resize(item, to: output, settings: settings)))
    let retainedGPS = retained[kCGImagePropertyGPSDictionary] as? NSDictionary
    try require((retainedGPS?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 42.5,
                "GPS latitude was lost when metadata preservation was enabled")
    let retainedEXIF = retained[kCGImagePropertyExifDictionary] as? NSDictionary
    try require(retainedEXIF?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:04 12:00:00",
                "EXIF timestamp was lost")
    settings.preserveMetadata = false
    let stripped = try properties(outputURL(ResizeEngine.resize(item, to: output, settings: settings)))
    try require(stripped[kCGImagePropertyGPSDictionary] == nil, "GPS metadata was retained despite stripping")
    let strippedEXIF = stripped[kCGImagePropertyExifDictionary] as? NSDictionary
    try require(strippedEXIF?[kCGImagePropertyExifDateTimeOriginal] == nil, "EXIF timestamp was retained despite stripping")
    for result in [retained, stripped] {
        try require(result[kCGImagePropertyProfileName] as? String == original[kCGImagePropertyProfileName] as? String,
                    "Color profile changed across resize")
    }
}

test("16-bit PNG and TIFF retain channel depth and precision") {
    let width = 80
    let height = 40
    let sample: [UInt16] = [32768, 20000, 40000, 65535]
    var words = [UInt16]()
    words.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) { words.append(contentsOf: sample) }
    let data = words.withUnsafeBytes { Data($0) }
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 16,
                        bitsPerPixel: 64, bytesPerRow: width * 8,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent)!
    let input = try fixture("sixteen-bit.png", image: image)
    let item = try ResizeEngine.inspect(input)
    guard let decodedInput = CGImageSourceCreateImageAtIndex(try source(input), 0, nil) else {
        throw TestFailure("Could not decode 16-bit fixture")
    }
    try require(decodedInput.bitsPerComponent == 16, "Fixture was not encoded with 16-bit channels")
    for format in [OutputFormat.png, .tiff] {
        var settings = ResizeSettings()
        settings.width = 40
        settings.format = format
        let url = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
        guard let result = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else {
            throw TestFailure("Could not decode 16-bit output")
        }
        try require(result.bitsPerComponent == 16, "\(format) lost 16-bit precision")
        var readback = [UInt16](repeating: 0, count: result.width * result.height * 4)
        try readback.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: result.width, height: result.height,
                                          bitsPerComponent: 16, bytesPerRow: result.width * 8,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TestFailure("Could not inspect 16-bit channels")
            }
            context.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        }
        let offset = ((result.height / 2) * result.width + result.width / 2) * 4
        for channel in 0..<4 {
            try require(abs(Int(readback[offset + channel]) - Int(sample[channel])) <= 8,
                        "\(format) rounded channel \(channel) to 8-bit precision: \(readback[offset + channel])")
        }
    }
}

test("Grayscale sources resize into valid neutral RGB pixels") {
    let width = 80
    let height = 40
    var gray = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width { gray[y * width + x] = x < width / 2 ? 0 : 255 }
    }
    let provider = CGDataProvider(data: Data(gray) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                        bitsPerPixel: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent)!
    let input = try fixture("grayscale.png", image: image)
    var settings = ResizeSettings()
    settings.width = 40
    let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    let url = try outputURL(result)
    try assertDimensions(url, 40, 20)
    try require(CGImageSourceGetType(try source(url)) as String? == "public.jpeg" && url.pathExtension == "jpg",
                "Default reduction did not create a valid JPEG output")
    let rgba = try pixels(url)
    try requireColor(color(rgba, x: 0.2, y: 0.5), [0, 0, 0, 255], "Grayscale black")
    try requireColor(color(rgba, x: 0.8, y: 0.5), [255, 255, 255, 255], "Grayscale white")
}

test("Duplicate basenames and same-folder output never overwrite files") {
    let first = try fixture("first/shared.png")
    let second = try fixture("second/shared.png", image: bitmap(width: 100, height: 50))
    var settings = ResizeSettings()
    settings.width = 40
    settings.format = .original
    let firstResult = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(first), to: output, settings: settings))
    let firstBytes = try Data(contentsOf: firstResult)
    let secondResult = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(second), to: output, settings: settings))
    try require(firstResult != secondResult, "Duplicate basenames overwrote an existing result")
    try require(try Data(contentsOf: firstResult) == firstBytes, "First output changed after the second resize")
    let originalBytes = try Data(contentsOf: first)
    let sameFolder = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(first), to: first.deletingLastPathComponent(), settings: settings))
    try require(sameFolder != first, "Resizing into the source folder replaced the original")
    try require(try Data(contentsOf: first) == originalBytes, "Source bytes were modified")
    try assertDimensions(sameFolder, 40, 20)
}

test("Default smaller original-format images skip without writing output") {
    let url = try fixture("already-small.png")
    let originalBytes = try Data(contentsOf: url)
    var settings = ResizeSettings()
    settings.format = .original
    let result = try ResizeEngine.resize(ResizeEngine.inspect(url), to: output, settings: settings)
    try requireSkipped(result, width: 80, height: 40)
    try require(try Data(contentsOf: url) == originalBytes, "Original source bytes changed")
}

test("Default smaller images skip even when metadata stripping is requested") {
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    let url = try fixture("small-gps.jpg", type: "public.jpeg",
                          properties: [kCGImagePropertyGPSDictionary: gps])
    var settings = ResizeSettings()
    settings.preserveMetadata = false
    let result = try ResizeEngine.resize(ResizeEngine.inspect(url), to: output, settings: settings)
    try requireSkipped(result, width: 80, height: 40)
    try require(try properties(url)[kCGImagePropertyGPSDictionary] != nil, "Skip changed original GPS metadata")
}

test("Default smaller and enabled equal-size targets skip across all formats, watermarks and metadata choices") {
    let input = try fixture("skip-settings.png")
    let sourceChecksum = SHA256.hash(data: try Data(contentsOf: input))
    let folder = work.appendingPathComponent("skip-settings-output", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Existing output must remain unchanged".utf8).write(to: folder.appendingPathComponent("existing.txt"))
    let before = try directorySnapshot(folder)
    for allowUpscaling in [false, true] {
      for mode in ResizeMode.allCases where mode != .originalDimensions {
        for format in OutputFormat.allCases {
            for watermark in [false, true] {
                for metadata in [false, true] {
                    var settings = ResizeSettings()
                    settings.mode = mode
                    settings.allowUpscaling = allowUpscaling
                    settings.width = allowUpscaling ? 80 : 1600
                    settings.height = allowUpscaling ? 40 : 1600
                    settings.percent = allowUpscaling ? 100 : 150
                    settings.format = format
                    settings.watermarkEnabled = watermark
                    settings.watermarkText = "SAMPLE"
                    settings.preserveMetadata = metadata
                    let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: folder, settings: settings)
                    try requireSkipped(result, width: 80, height: 40)
                }
            }
        }
      }
    }
    try require(try directorySnapshot(folder) == before, "Skip settings wrote, removed or changed output files")
    try require(try SHA256.hash(data: Data(contentsOf: input)) == sourceChecksum, "Skip settings changed source checksum")
}

test("Equal bounds, 100 percent and rounding to unchanged dimensions all skip") {
    let input = try fixture("skip-equal.png")
    let before = Set(try fileManager.contentsOfDirectory(atPath: output.path))
    var choices = [ResizeSettings]()
    for mode in [ResizeMode.longestEdge, .fit, .width, .height] {
        var settings = ResizeSettings()
        settings.mode = mode
        settings.width = 80
        settings.height = 40
        choices.append(settings)
    }
    for percent in [100.0, 99.9, 100.1] {
        var settings = ResizeSettings()
        settings.mode = .percent
        settings.percent = percent
        choices.append(settings)
    }
    for var settings in choices {
      for allowUpscaling in [false, true] {
        settings.allowUpscaling = allowUpscaling
        settings.watermarkEnabled = true
        settings.watermarkText = "SAMPLE"
        settings.format = .jpeg
        settings.preserveMetadata = false
        try requireSkipped(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings), width: 80, height: 40)
      }
    }
    try require(Set(try fileManager.contentsOfDirectory(atPath: output.path)) == before, "Equality skip wrote output files")
}

test("Mixed batches enlarge small images, skip equal dimensions, and reduce large images") {
    let small = try fixture("batch-skip/small.png")
    let equal = try fixture("batch-skip/equal.png", image: bitmap(width: 300, height: 150))
    let large = try fixture("batch-skip/large.png", image: bitmap(width: 600, height: 300))
    let inputs = [small, equal, large]
    let checksums = try inputs.map { SHA256.hash(data: try Data(contentsOf: $0)) }
    var settings = ResizeSettings()
    settings.width = 300
    settings.format = .png
    settings.watermarkEnabled = true
    settings.watermarkText = "SAMPLE"
    settings.preserveMetadata = false
    for allowUpscaling in [false, true] {
        settings.allowUpscaling = allowUpscaling
        let folder = work.appendingPathComponent("mixed-batch-output-\(allowUpscaling)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let results = try inputs.map { try ResizeEngine.resize(ResizeEngine.inspect($0), to: folder, settings: settings) }
        try requireSkipped(results[1], width: 300, height: 150)
        if allowUpscaling {
            try require(!results[0].skipped, "Enabled mixed batch skipped a small image")
            try assertDimensions(outputURL(results[0]), 300, 150)
        } else {
            try requireSkipped(results[0], width: 80, height: 40)
        }
        try require(!results[2].skipped, "Mixed batch skipped its reduction")
        try assertDimensions(outputURL(results[2]), 300, 150)
        try require(try fileManager.contentsOfDirectory(atPath: folder.path).count == (allowUpscaling ? 2 : 1),
                    "Mixed batch wrote the wrong number of files for its enlargement choice")
    }
    for (input, checksum) in zip(inputs, checksums) {
        try require(try SHA256.hash(data: Data(contentsOf: input)) == checksum, "Mixed batch changed a source")
    }
}

test("Oriented fit reduces when only one displayed dimension exceeds its bound") {
    let input = try fixture("fit-one-over.tiff", type: "public.tiff", image: bitmap(width: 800, height: 400),
                            properties: [kCGImagePropertyOrientation: 6])
    let item = try ResizeEngine.inspect(input)
    try require(item.width == 400 && item.height == 800, "Fixture orientation dimensions are wrong")
    var settings = ResizeSettings()
    settings.mode = .fit
    settings.width = 500
    settings.height = 500
    settings.format = .png
    let result = try ResizeEngine.resize(item, to: output, settings: settings)
    try require(!result.skipped, "Fit skipped because only one dimension was too large")
    try assertDimensions(outputURL(result), 250, 500)
    let rgba = try pixels(outputURL(result))
    try requireColor(color(rgba, x: 0.2, y: 0.2), [0, 0, 255, 255], "Oriented fit pixels")
}

test("Corrupted, animated and multipage images are rejected") {
    let corrupt = work.appendingPathComponent("corrupt.jpg")
    try Data("This is not image data".utf8).write(to: corrupt)
    try requireThrows("Accepted corrupted data") { _ = try ResizeEngine.inspect(corrupt) }
    let animated = try fixture("animated.gif", type: "com.compuserve.gif", frames: 2)
    try require(CGImageSourceGetCount(try source(animated)) == 2, "Animated fixture is incomplete")
    try requireThrows("Accepted animated GIF and would silently discard frames") { _ = try ResizeEngine.inspect(animated) }
    let multipage = try fixture("multipage.tiff", type: "public.tiff", frames: 2)
    try require(CGImageSourceGetCount(try source(multipage)) == 2, "Multipage fixture is incomplete")
    try requireThrows("Accepted multipage TIFF and would silently discard pages") { _ = try ResizeEngine.inspect(multipage) }
}

test("Default smaller images skip with disabled watermark") {
    let input = try fixture("watermark-disabled.png")
    let original = try Data(contentsOf: input)
    var settings = ResizeSettings()
    settings.watermarkEnabled = false
    settings.watermarkText = "Do not render this text"
    let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    try requireSkipped(result, width: 80, height: 40)
    try require(try Data(contentsOf: input) == original, "Skip changed source bytes")
}

test("Zero watermark strength has identical pixels to disabled watermark encoding") {
    let input = try fixture("watermark-zero.png", image: bitmap(width: 640, height: 400, transparent: true))
    var settings = ResizeSettings()
    settings.width = 320
    settings.watermarkText = "SAMPLE"
    settings.watermarkStrength = 0
    for format in [OutputFormat.png, .jpeg] {
        settings.format = format
        settings.watermarkEnabled = false
        let plain = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        settings.watermarkEnabled = true
        let zero = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        let plainPixels = try pixels(plain)
        let zeroPixels = try pixels(zero)
        try require(plainPixels.0 == zeroPixels.0 && plainPixels.1 == zeroPixels.1 && plainPixels.2 == zeroPixels.2,
                    "Zero strength changed \(format) pixels compared with disabled watermark")
    }
    settings.format = .original
    settings.width = 1600
    let skipped = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    try requireSkipped(skipped, width: 640, height: 400)
}

test("Watermark strength increases visible contrast on white, black and colored images") {
    let cases: [(String, CGFloat, CGFloat, CGFloat)] = [
        ("white", 1, 1, 1), ("black", 0, 0, 0), ("colored", 0.14, 0.48, 0.82)
    ]
    for (name, red, green, blue) in cases {
        let width = 1000
        let height = 650
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let input = try fixture("watermark-strength-\(name).png", image: context.makeImage()!)
        let baseline = try pixels(plainReduction(input))
        var previousTotal = 0
        var previousMaximum = 0
        for strength in [0.1, 0.5, 1.0] {
            let url = try outputURL(watermarked(input, text: "SAMPLE", strength: strength))
            let rgba = try pixels(url)
            var total = 0
            var maximum = 0
            try require(rgba.0 == baseline.0 && rgba.1 == baseline.1, "Strength comparison dimensions differ")
            for pixel in 0..<(rgba.0 * rgba.1) {
                for channel in 0..<3 {
                    let difference = abs(Int(rgba.2[pixel * 4 + channel]) - Int(baseline.2[pixel * 4 + channel]))
                    total += difference
                    maximum = max(maximum, difference)
                }
            }
            try require(total > previousTotal && maximum > previousMaximum,
                        "Increasing strength did not increase \(name) watermark contrast at \(strength)")
            previousTotal = total
            previousMaximum = maximum
        }
    }
}

test("Enabled watermark rejects invalid strength; disabled smaller images skip") {
    let input = try fixture("watermark-invalid-strength.png")
    let original = try Data(contentsOf: input)
    let before = Set(try fileManager.contentsOfDirectory(atPath: output.path))
    let invalid: [Double] = [-0.1, 1.1, .nan, .infinity, -.infinity]
    for strength in invalid {
        try requireThrows("Accepted invalid enabled watermark strength \(strength)") {
            _ = try watermarked(input, strength: strength)
        }
    }
    try require(Set(try fileManager.contentsOfDirectory(atPath: output.path)) == before,
                "Invalid watermark strength left output files behind")
    for strength in invalid {
        var settings = ResizeSettings()
        settings.watermarkEnabled = false
        settings.watermarkStrength = strength
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        try requireSkipped(result, width: 80, height: 40)
        try require(try Data(contentsOf: input) == original, "Disabled invalid strength changed source bytes")
    }
}

test("Watermark reductions protect source and existing output files") {
    let input = try fixture("watermark-small.png", image: solidBitmap(width: 800, height: 500, white: 1))
    let original = try Data(contentsOf: input)
    var settings = ResizeSettings()
    settings.format = .original
    settings.width = 400
    settings.watermarkEnabled = true
    settings.watermarkText = "SAMPLE"
    let first = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    let firstURL = try outputURL(first)
    let firstBytes = try Data(contentsOf: firstURL)
    try require(!first.skipped, "Watermarked reduction was skipped")
    try assertDimensions(firstURL, 400, 250)
    try require(firstBytes != original, "Enabled watermark did not change output bytes")
    let changed = try changedPixels(pixels(plainReduction(input, longestEdge: 400)), pixels(firstURL))
    try require(changed.filter { $0 != 0 }.count > 500, "Watermark did not change visible pixels")
    let second = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    try require(try outputURL(second) != firstURL, "Second watermark overwrote first output")
    try require(try Data(contentsOf: firstURL) == firstBytes, "Watermark changed existing output")
    let besideSource = try ResizeEngine.resize(ResizeEngine.inspect(input), to: input.deletingLastPathComponent(), settings: settings)
    try require(try outputURL(besideSource) != input, "Watermark replaced its original source")
    try require(try Data(contentsOf: input) == original, "Watermark modified original source bytes")
}

test("Watermark follows orientation normalization and target resizing") {
    let input = try fixture("watermark-oriented.tiff", type: "public.tiff",
                            image: bitmap(width: 600, height: 400),
                            properties: [kCGImagePropertyOrientation: 6])
    var plain = ResizeSettings()
    plain.width = 300
    plain.format = .png
    let baseline = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: plain))
    let result = try watermarked(input, longestEdge: 300)
    let url = try outputURL(result)
    try assertDimensions(url, 200, 300)
    try require(!result.skipped, "Resized watermarked output reported passthrough")
    let rgba = try pixels(url)
    let expected: [[UInt8]] = [[0, 0, 255, 255], [255, 0, 0, 255], [255, 255, 0, 255], [0, 255, 0, 255]]
    let probes = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
    for (index, probe) in probes.enumerated() {
        try requireColor(color(rgba, x: probe.0, y: probe.1), expected[index], "Watermark disturbed orientation", tolerance: 70)
    }
    let changed = try changedPixels(pixels(baseline), rgba)
    try require(changed.contains(1), "Watermark was lost during resize")
}

test("Blank and oversized enabled watermark text fail without writing files") {
    let input = try fixture("watermark-invalid.png")
    let before = Set(try fileManager.contentsOfDirectory(atPath: output.path))
    for text in ["", "   \n\t", String(repeating: "A", count: 8193)] {
        try requireThrows("Accepted invalid watermark text") { _ = try watermarked(input, text: text) }
    }
    try require(Set(try fileManager.contentsOfDirectory(atPath: output.path)) == before,
                "Invalid watermark text left output files behind")
}

test("Unicode, long text, portrait, landscape and tiny watermarks remain visible") {
    let examples: [(String, Int, Int, String)] = [
        ("unicode", 900, 600, "样片 • Café • Αλέξανδρος • مرحبا"),
        ("long", 900, 600, String(repeating: "North Coast Photography — Private Preview • ", count: 12)),
        ("portrait", 360, 960, "SAMPLE"),
        ("landscape", 960, 360, "SAMPLE"),
        ("tiny", 32, 24, "SAMPLE")
    ]
    for (name, width, height, text) in examples {
        let input = try fixture("watermark-\(name).png", image: solidBitmap(width: width, height: height, white: 1))
        let result = try watermarked(input, text: text)
        let url = try outputURL(result)
        let before = try pixels(plainReduction(input))
        let after = try pixels(url)
        try require(after.0 < width || after.1 < height, "\(name) renderer fixture did not actually reduce")
        let changed = try changedPixels(before, after, threshold: 0)
        try require(changed.contains(1), "\(name) watermark produced no visible pixels")
        if name == "portrait" || name == "landscape" {
            for row in 0..<2 {
                for column in 0..<2 {
                    var quadrantCount = 0
                    for y in (row * after.1 / 2)..<((row + 1) * after.1 / 2) {
                        for x in (column * after.0 / 2)..<((column + 1) * after.0 / 2) {
                            quadrantCount += Int(changed[y * after.0 + x])
                        }
                    }
                    try require(quadrantCount > 20, "\(name) watermark did not repeat across quadrant \(row),\(column)")
                }
            }
        }
    }
}

test("Watermark retains transparent PNG background and partial alpha strokes") {
    let input = try fixture("watermark-alpha.png", image: bitmap(width: 600, height: 400, transparent: true))
    let url = try outputURL(watermarked(input, longestEdge: 300))
    try assertDimensions(url, 300, 200)
    let rgba = try pixels(url)
    let alphas = stride(from: 3, to: rgba.2.count, by: 4).map { rgba.2[$0] }
    try require(alphas.filter { $0 == 0 }.count > alphas.count / 5, "Watermark flattened transparent background")
    try require(alphas.filter { $0 == 255 }.count > alphas.count / 3, "Watermark reduced opaque source alpha")
    try require(alphas.contains { $0 > 0 && $0 < 255 }, "Watermark did not produce partial alpha strokes")
}

test("Watermark retains 16-bit channels and Display P3 profile") {
    let width = 400
    let height = 300
    let sample: [UInt16] = [32768, 20000, 40000, 65535]
    var words = [UInt16]()
    words.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) { words.append(contentsOf: sample) }
    let data = words.withUnsafeBytes { Data($0) }
    let provider = CGDataProvider(data: data as CFData)!
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 16,
                        bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                        bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let input = try fixture("watermark-p3-16.png", image: image)
    let originalProfile = try properties(input)[kCGImagePropertyProfileName] as? String
    for format in [OutputFormat.png, .tiff] {
        let url = try outputURL(watermarked(input, format: format))
        guard let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else {
            throw TestFailure("Cannot decode watermarked 16-bit output")
        }
        try require(decoded.bitsPerComponent == 16, "Watermark reduced \(format) to 8-bit channels")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == originalProfile && originalProfile != nil,
                    "Watermark changed the Display P3 color profile")
        let outputWidth = decoded.width
        let outputHeight = decoded.height
        let outputCount = outputWidth * outputHeight
        var readback = [UInt16](repeating: 0, count: outputCount * 4)
        try readback.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: outputWidth, height: outputHeight,
                                          bitsPerComponent: 16, bytesPerRow: outputWidth * 8, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TestFailure("Cannot inspect watermarked high-depth channels")
            }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        }
        var unchanged = 0
        var changed = 0
        for pixel in 0..<outputCount {
            let matching = (0..<4).allSatisfy { abs(Int(readback[pixel * 4 + $0]) - Int(sample[$0])) <= 8 }
            if matching { unchanged += 1 } else { changed += 1 }
        }
        try require(unchanged > outputCount / 2, "Watermark damaged untouched 16-bit channel precision")
        try require(changed > 100, "Watermark was absent from high-depth output")
    }
}

test("White and black watermark strokes remain faint and occupy narrow outlines") {
    for (name, white) in [("white", CGFloat(1)), ("black", CGFloat(0))] {
        let input = try fixture("watermark-outline-\(name).png", image: solidBitmap(width: 1601, height: 1001, white: white))
        let url = try outputURL(watermarked(input, text: "O"))
        let before = try pixels(plainReduction(input))
        let after = try pixels(url)
        let changed = try changedPixels(before, after)
        let count = changed.filter { $0 != 0 }.count
        try require(count > changed.count / 1000, "Watermark is invisible against \(name)")
        try require(count < changed.count / 5, "Watermark covers too much of the \(name) background")
        var maximumContrast = 0
        for pixel in 0..<changed.count where changed[pixel] != 0 {
            for channel in 0..<3 {
                maximumContrast = max(maximumContrast, abs(Int(after.2[pixel * 4 + channel]) - Int(before.2[pixel * 4 + channel])))
            }
        }
        try require(maximumContrast <= 80, "Watermark is too strong against \(name): contrast \(maximumContrast)/255")
        let complete = components(mask: changed, width: 1600, height: 1000).filter {
            $0.width >= 15 && $0.height >= 15 && $0.minX > 0 && $0.minY > 0 && $0.maxX < 1599 && $0.maxY < 999
        }
        try require(complete.count >= 5, "Watermark did not repeat visible glyphs")
        try require(complete.allSatisfy { Double($0.count) / Double($0.width * $0.height) < 0.4 },
                    "Watermark contains broad filled regions rather than thin glyph outlines")
        let preview = root.deletingLastPathComponent().appendingPathComponent("watermark-preview", isDirectory: true)
        try fileManager.createDirectory(at: preview, withIntermediateDirectories: true)
        try Data(contentsOf: url).write(to: preview.appendingPathComponent("outline-\(name).png"), options: .atomic)
    }
}

test("Layered PSD and TIFF exports use the visible composite and contain no editable layers") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-export"))
    try require(LayerFixtures.psdLayerCount(try Data(contentsOf: documents.psd)) == -3,
                "PSD fixture does not contain three real layers and composite transparency")
    try require(LayerFixtures.tiffTags(try Data(contentsOf: documents.tiff)).contains(37724),
                "TIFF fixture lacks Photoshop ImageSourceData")
    let probes: [(Double, Double, [UInt8])] = [
        (0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
        (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])
    ]
    for input in [documents.psd, documents.tiff] {
        let original = try Data(contentsOf: input)
        let originalProfile = try properties(input)[kCGImagePropertyProfileName] as? String
        let item = try ResizeEngine.inspect(input)
        try require(item.width == 80 && item.height == 48, "Layered input dimensions are incorrect")
        for format in [OutputFormat.jpeg, .png, .tiff] {
            for preserveMetadata in [true, false] {
                var settings = ResizeSettings()
                settings.width = 40
                settings.format = format
                settings.quality = 1
                settings.preserveMetadata = preserveMetadata
                let url = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
                try assertDimensions(url, 40, 24)
                try require(CGImageSourceGetCount(try source(url)) == 1, "Flattened export has multiple image frames")
                let rgba = try pixels(url)
                for (x, y, expected) in probes {
                    let expectedPixel: [UInt8]
                    if format == .jpeg {
                        // Opaque white matte: the transparent quadrants become
                        // white and half-green, while visible layers stay red/olive.
                        expectedPixel = expected[3] == 0 ? [255, 255, 255, 255]
                            : expected[3] == 128 ? [127, 255, 127, 255] : expected
                    } else { expectedPixel = expected }
                    try requireColor(color(rgba, x: x, y: y), expectedPixel,
                                     "\(input.pathExtension) \(format) visible composite at \(x),\(y)",
                                     tolerance: format == .jpeg ? 8 : 3)
                }
                let encoded = try Data(contentsOf: url)
                try require(encoded.range(of: LayerFixtures.layerMarker) == nil, "Export retained Photoshop layer payload")
                if format == .tiff {
                    try require(!LayerFixtures.tiffTags(encoded).contains(37724), "Export retained TIFF ImageSourceData tag")
                }
                let adobe = try properties(url)["{8BIM}"] as? NSDictionary
                try require(adobe?["LayerNames"] == nil, "Export retained layer-name metadata")
                try require(try properties(url)[kCGImagePropertyProfileName] as? String == originalProfile && originalProfile != nil,
                            "Flattened export lost its source ICC profile")
            }
        }
        try require(try Data(contentsOf: input) == original, "Flattening changed the original layered file")
    }
}

test("Layered16-bit PSD and TIFF retain precision and alpha after reduction and enlargement") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-depth"))
    try require(LayerFixtures.psdLayerCount(try Data(contentsOf: documents.psd16)) == -3,
                "16-bit PSD fixture lacks its real Lr16 layers")
    let probes: [(Double, Double, [UInt16])] = [
        (0.2, 0.2, [65535, 0, 0, 65535]), (0.8, 0.2, [0, 0, 0, 0]),
        (0.2, 0.8, [32639, 32896, 0, 65535]), (0.8, 0.8, [0, 32896, 0, 32896])
    ]
    for input in [documents.psd16, documents.tiff16] {
      let item = try ResizeEngine.inspect(input)
      let originalProfile = try properties(input)[kCGImagePropertyProfileName] as? String
      let original = try Data(contentsOf: input)
      for format in [OutputFormat.png, .tiff] {
       for targetWidth in [40, 160] {
        var settings = ResizeSettings()
        settings.width = targetWidth
        settings.allowUpscaling = true
        settings.format = format
        let url = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
        guard let image = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else {
            throw TestFailure("Cannot decode flattened 16-bit image")
        }
        try require(image.width == targetWidth && image.height == targetWidth * 3 / 5 && image.bitsPerComponent == 16,
                    "Flattening lost 16-bit channel depth or changed dimensions")
        var words = [UInt16](repeating: 0, count: image.width * image.height * 4)
        try words.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 16, bytesPerRow: image.width * 8,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TestFailure("Cannot inspect layered 16-bit composite")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        for (x, y, expected) in probes {
            let pixel = (Int(Double(image.height) * y) * image.width + Int(Double(image.width) * x)) * 4
            for channel in 0..<4 {
                try require(abs(Int(words[pixel + channel]) - Int(expected[channel])) <= 8,
                            "Flattened \(input.pathExtension) \(format) changed precise composite channel \(channel): \(words[pixel + channel])")
            }
        }
        let encoded = try Data(contentsOf: url)
        try require(encoded.range(of: LayerFixtures.layerMarker) == nil, "16-bit export retained layer bytes")
        try require(!LayerFixtures.tiffTags(encoded).contains(37724), "16-bit export retained TIFF layers")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == originalProfile && originalProfile != nil,
                    "16-bit flattened export lost ICC profile")
       }
      }
      try require(try Data(contentsOf: input) == original, "Flattening changed layered 16-bit source")
    }
}

test("Original-format PSD and TIFF outputs are flattened documents") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-original"))
    for input in [documents.psd, documents.psd16, documents.tiff, documents.tiff16] {
        var settings = ResizeSettings()
        settings.width = 40
        settings.format = .original
        let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        try assertDimensions(url, 40, 24)
        if input == documents.psd16 || input == documents.tiff16 {
            let image = CGImageSourceCreateImageAtIndex(try source(url), 0, nil)
            try require(image?.bitsPerComponent == 16, "Original-format flattening lost 16-bit precision")
        }
        let encoded = try Data(contentsOf: url)
        let type = CGImageSourceGetType(try source(url)) as String?
        if type == "com.adobe.photoshop-image" {
            guard let count = LayerFixtures.psdLayerCount(encoded) else {
                throw TestFailure("Cannot parse original PSD output's layer section")
            }
            // A flat transparent PSD may contain one raster layer. Its saved
            // layer stack must no longer contain the original editable layers.
            try require(abs(count) <= 1, "Original PSD output retained multiple editable layers")
            for name in ["Red left base", "Green at 50 percent", "Hidden magenta"] {
                try require(encoded.range(of: Data(name.utf8)) == nil, "Flattened PSD retained original layer \(name)")
            }
        } else if type == "public.tiff" {
            try require(!LayerFixtures.tiffTags(encoded).contains(37724), "Original TIFF output retained editable layers")
        } else {
            try require(type == "public.png", "Unexpected fallback format for layered source")
        }
        try require(encoded.range(of: LayerFixtures.layerMarker) == nil, "Original-format output retained layer payload")
        let readbackURL: URL
        if type == "com.adobe.photoshop-image" {
            // Decode through a second reduction: this also catches a native
            // PSD writer whose composite cannot round-trip its transparency.
            var readbackSettings = ResizeSettings()
            readbackSettings.width = 20
            readbackSettings.format = .png
            readbackURL = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(url), to: output, settings: readbackSettings))
        } else { readbackURL = url }
        let rgba = try pixels(readbackURL)
        try requireColor(color(rgba, x: 0.2, y: 0.2), [255, 0, 0, 255], "Original-format red base", tolerance: 3)
        try requireColor(color(rgba, x: 0.2, y: 0.8), [127, 128, 0, 255], "Original-format layer opacity", tolerance: 3)
        try requireColor(color(rgba, x: 0.8, y: 0.8), [0, 128, 0, 128], "Original-format half-transparent green", tolerance: 3)
    }
}

test("Opaque layered PSD keeps native PSD output and round-trips its flattened colors") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-opaque"))
    let original = try Data(contentsOf: documents.opaquePSD)
    try require(LayerFixtures.psdLayerCount(original) == 3, "Opaque fixture does not have three real layers")
    var settings = ResizeSettings()
    settings.width = 40
    settings.format = .original
    let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(documents.opaquePSD), to: output, settings: settings))
    try require(CGImageSourceGetType(try source(url)) as String? == "com.adobe.photoshop-image", "Opaque PSD did not retain native PSD format")
    try require(url.pathExtension.lowercased() == "psd", "Native opaque PSD has an incorrect filename extension")
    let encoded = try Data(contentsOf: url)
    guard let count = LayerFixtures.psdLayerCount(encoded) else { throw TestFailure("Cannot parse flat opaque PSD") }
    try require(abs(count) <= 1, "Opaque PSD retained multiple editable layers")
    for name in ["Red left base", "Green at 50 percent", "Hidden magenta"] {
        try require(encoded.range(of: Data(name.utf8)) == nil, "Opaque output retained original layer names")
    }
    settings.width = 20
    settings.format = .png
    let readback = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(url), to: output, settings: settings))
    let rgba = try pixels(readback)
    for x in [0.2, 0.8] {
        try requireColor(color(rgba, x: x, y: 0.2), [255, 0, 0, 255], "Opaque PSD red", tolerance: 3)
        try requireColor(color(rgba, x: x, y: 0.8), [127, 128, 0, 255], "Opaque PSD layer opacity", tolerance: 3)
    }
    try require(try Data(contentsOf: documents.opaquePSD) == original, "Opaque PSD source was modified")
}

test("Grayscale and CMYK PSD composites match independent native color controls") {
    let documents = try LayerFixtures.createColorModes(in: work.appendingPathComponent("layered-color-modes"))
    for document in documents {
        let original = try Data(contentsOf: document.url)
        try require(LayerFixtures.psdLayerCount(original) == -3, "Non-RGB fixture lacks its genuine three layers")
        let control = try fixture("\(document.url.deletingPathExtension().lastPathComponent)-control.png", image: document.reference)
        var settings = ResizeSettings()
        settings.width = 40
        settings.format = .png
        let expected = try pixels(outputURL(ResizeEngine.resize(ResizeEngine.inspect(control), to: output, settings: settings)))
        for format in [OutputFormat.png, .tiff, .jpeg] {
            settings.format = format
            settings.quality = 1
            let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(document.url), to: output, settings: settings))
            try assertDimensions(url, 40, 24)
            let actual = try pixels(url)
            if document.depth == 16 && format != .jpeg {
                let image = CGImageSourceCreateImageAtIndex(try source(url), 0, nil)
                try require(image?.bitsPerComponent == 16, "Non-RGB PSD export lost16-bit channels")
            }
            for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                let pixel = color(expected, x: x, y: y)
                let target = format == .jpeg ? pixel.prefix(3).map { UInt8(clamping: Int($0) + 255 - Int(pixel[3])) } + [255] : pixel
                try requireColor(color(actual, x: x, y: y), target,
                                 "\(document.url.lastPathComponent) \(format) color control at \(x),\(y)",
                                 tolerance: format == .jpeg ? 8 : 3)
            }
            let adobe = try properties(url)["{8BIM}"] as? NSDictionary
            try require(adobe?["LayerNames"] == nil, "Non-RGB export kept layer metadata")
        }
        try require(try Data(contentsOf: document.url) == original, "Non-RGB PSD source changed during flattening")
    }
}

test("Equal-size layered inputs skip and preserve their editable layers") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-skip"))
    let beforeOutput = try directorySnapshot(output)
    for input in [documents.psd, documents.psd16, documents.tiff, documents.tiff16] {
        let original = try Data(contentsOf: input)
        let item = try ResizeEngine.inspect(input)
        for format in [OutputFormat.original, .jpeg, .png, .tiff] {
            for watermark in [false, true] {
                var settings = ResizeSettings()
                settings.width = 80
                settings.format = format
                settings.preserveMetadata = !watermark
                settings.watermarkEnabled = watermark
                settings.watermarkText = "SAMPLE"
                try requireSkipped(ResizeEngine.resize(item, to: output, settings: settings), width: 80, height: 48)
            }
        }
        try require(try Data(contentsOf: input) == original, "Skipping changed the editable layered source")
    }
    try require(try directorySnapshot(output) == beforeOutput, "Skipping layered files wrote an output")
}

test("PSD without a trustworthy merged composite returns a clear compatibility error") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-incompatible"))
    let beforeOutput = try directorySnapshot(output)
    for input in [documents.incompatiblePSD, documents.missingCompositePSD] {
        let original = try Data(contentsOf: input)
        do {
            let item = try ResizeEngine.inspect(input)
            var settings = ResizeSettings()
            settings.width = 40
            _ = try ResizeEngine.resize(item, to: output, settings: settings)
            throw TestFailure("PSD without a saved composite was silently exported")
        } catch let failure as TestFailure { throw failure }
        catch {
            try require(error.localizedDescription.lowercased().contains("compatib"),
                        "PSD composite error does not explain Photoshop compatibility: \(error.localizedDescription)")
        }
        try require(try Data(contentsOf: input) == original, "Rejected PSD source was changed")
    }
    try require(try directorySnapshot(output) == beforeOutput, "Rejected PSD produced output files")
}

test("Crop planning applies every resize mode to the crop before reduction or enlargement") {
    var settings = ResizeSettings()
    settings.allowUpscaling = true
    settings.crop = CropSelection(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let cases: [(ResizeMode, Int, Int, Double, Int, Int)] = [
        (.longestEdge, 1000, 600, 50, 1000, 500), (.fit, 900, 600, 50, 900, 450),
        (.width, 900, 600, 50, 900, 450), (.height, 900, 200, 50, 400, 200),
        (.percent, 900, 600, 50, 1000, 500),
        (.longestEdge, 3000, 2000, 150, 3000, 1500), (.fit, 3000, 2000, 150, 3000, 1500),
        (.width, 3000, 2000, 150, 3000, 1500), (.height, 3000, 2000, 150, 4000, 2000),
        (.percent, 3000, 2000, 150, 3000, 1500)
    ]
    for (mode, width, height, percent, expectedWidth, expectedHeight) in cases {
        settings.mode = mode; settings.width = width; settings.height = height; settings.percent = percent
        let plan = try ResizeEngine.outputPlan(width: 4000, height: 2000, settings: settings)
        try require(plan.cropRect == CGRect(x: 1000, y: 500, width: 2000, height: 1000) && plan.isCropped,
                    "Crop plan has wrong source rectangle")
        try require(plan.width == expectedWidth && plan.height == expectedHeight && !plan.skipped,
                    "\(mode) resized the full image instead of the crop")
    }
    settings.mode = .longestEdge; settings.width = 1600; settings.crop = nil
    let full = try ResizeEngine.outputPlan(width: Int.max, height: Int.max, settings: settings)
    try require(full.cropWidth == Int.max && full.cropHeight == Int.max && full.width == 1600 && full.height == 1600 && !full.isCropped,
                "Uncropped planning overflowed huge source dimensions")
    settings.crop = CropSelection(width: 0.5, height: 0.5)
    let hugeCrop = try ResizeEngine.outputPlan(width: Int.max, height: Int.max, settings: settings)
    try require(hugeCrop.cropWidth > 0 && hugeCrop.cropWidth < Int.max && hugeCrop.width == 1600 && hugeCrop.height == 1600,
                "Crop planning overflowed or introduced an arbitrary dimension limit")
    settings.crop = CropSelection()
    let unchanged = try ResizeEngine.outputPlan(width: 4000, height: 2000, settings: settings)
    settings.crop = nil
    let disabled = try ResizeEngine.outputPlan(width: 4000, height: 2000, settings: settings)
    try require(!unchanged.isCropped && unchanged.cropRect == disabled.cropRect && unchanged.width == disabled.width && unchanged.height == disabled.height,
                "A full-frame crop differs from disabled cropping")
}

test("Fixed crop aspects stay centered and consistent across image shapes; tiny crops remain in bounds") {
    let ratios: [(CropAspect, Double)] = [(.square, 1), (.portrait9x16, 9.0 / 16), (.landscape16x9, 16.0 / 9),
        (.portrait2x3, 2.0 / 3), (.landscape3x2, 3.0 / 2), (.portrait4x5, 4.0 / 5), (.landscape5x4, 5.0 / 4)]
    for (aspect, ratio) in ratios {
        let crop = CropSelection(x: 0.2, y: 0.1, width: 0.6, height: 0.7, aspect: aspect)
        for (width, height) in [(4000, 3000), (2000, 4000), (120, 80)] {
            let rect = try crop.pixelRect(width: width, height: height)
            try require(abs(rect.width - rect.height * ratio) <= 1.5, "\(aspect) changed ratio across source shapes")
            try require(abs(rect.midX - Double(width) * 0.5) <= 0.51 && abs(rect.midY - Double(height) * 0.45) <= 0.51,
                        "Fixed-ratio crop moved away from the selected center")
            try require(rect.minX >= Double(width) * 0.2 - 1 && rect.maxX <= Double(width) * 0.8 + 1 &&
                        rect.minY >= Double(height) * 0.1 - 1 && rect.maxY <= Double(height) * 0.8 + 1,
                        "Fixed aspect extended outside its selected box")
        }
        for (width, height) in [(1, 1), (1, 2), (2, 1), (3, 5)] {
            let tiny = CropSelection(x: 0.9999, y: 0.9999, width: 0.0001, height: 0.0001, aspect: aspect)
            let rect = try tiny.pixelRect(width: width, height: height)
            try require(rect.width >= 1 && rect.height >= 1 && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= Double(width) && rect.maxY <= Double(height),
                        "Subpixel crop became empty or escaped a tiny image")
            try require(rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded() && rect.width == rect.width.rounded() && rect.height == rect.height.rounded(),
                        "Crop rectangle contains fractional pixel coordinates")
        }
    }
    let free = try CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7).pixelRect(width: 240, height: 120)
    try require(free == CGRect(x: 48, y: 18, width: 156, height: 84), "Free crop changed the normalized rectangle")
}

test("Crop settings reject invalid bounds and safely restore a Codable selection") {
    let valid = CropSelection(x: 0.123, y: 0.234, width: 0.5, height: 0.6, aspect: .portrait4x5)
    let restored = try JSONDecoder().decode(CropSelection.self, from: JSONEncoder().encode(valid))
    try require(restored == valid, "Saved crop selection did not round-trip all fields and aspect")
    let invalid = [CropSelection(x: .nan), CropSelection(y: .infinity), CropSelection(width: -.infinity),
                   CropSelection(height: .nan), CropSelection(x: -0.001), CropSelection(y: -0.001),
                   CropSelection(width: 0), CropSelection(height: -0.1), CropSelection(x: 0.9, width: 0.2),
                   CropSelection(y: 0.9, height: 0.2), CropSelection(width: 1.01)]
    for crop in invalid {
        try requireThrows("Accepted invalid crop \(crop)") { _ = try crop.pixelRect(width: 80, height: 40) }
    }
    try requireThrows("Accepted zero-width source crop bounds") { _ = try valid.pixelRect(width: 0, height: 40) }
    try requireThrows("Accepted negative-height source crop bounds") { _ = try valid.pixelRect(width: 80, height: -1) }
    let badJSON = Data(#"{"x":-0.2,"y":0,"width":1,"height":1,"aspect":"free"}"#.utf8)
    let badSavedCrop = try JSONDecoder().decode(CropSelection.self, from: badJSON)
    try requireThrows("Restored out-of-bounds crop was accepted") { _ = try badSavedCrop.pixelRect(width: 80, height: 40) }
    let roundoff = try CropSelection(x: -1e-13, width: 1 + 1e-13).pixelRect(width: 80, height: 40)
    try require(roundoff == CGRect(x: 0, y: 0, width: 80, height: 40), "Harmless saved-coordinate roundoff was not clamped")
    let input = try fixture("crop-invalid.png")
    let before = try directorySnapshot(output)
    var settings = ResizeSettings(); settings.width = 40; settings.crop = CropSelection(width: 0)
    try requireThrows("Invalid crop wrote an output") { _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings) }
    try require(try directorySnapshot(output) == before, "Invalid crop left output files")
}

test("Asymmetric crops use displayed top-left coordinates for every EXIF orientation when reducing and enlarging") {
    let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                    [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
    let palette: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    let probes = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
    for orientation in 1...8 {
        let input = try fixture("crop-orientation-\(orientation).tiff", type: "public.tiff", image: bitmap(width: 240, height: 120),
                                properties: [kCGImagePropertyOrientation: orientation])
        let original = try Data(contentsOf: input)
        let rotated = orientation >= 5
        let targets = [(rotated ? 84 : 78, rotated ? 39 : 78, rotated ? 84 : 42),
                       (rotated ? 336 : 312, rotated ? 156 : 312, rotated ? 336 : 168)]
        for (edge, width, height) in targets {
            var settings = ResizeSettings(); settings.format = .png; settings.width = edge
            settings.allowUpscaling = true
            settings.crop = CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7)
            let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
            try assertDimensions(url, width, height)
            let rgba = try pixels(url)
            for (index, probe) in probes.enumerated() {
                try requireColor(color(rgba, x: probe.0, y: probe.1), palette[expected[orientation - 1][index]],
                                 "Crop picked the wrong displayed quadrant for EXIF\(orientation) at edge\(edge)", tolerance: 3)
            }
            let outputOrientation = (try properties(url)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            try require(outputOrientation == 1, "Cropped output retained EXIF rotation")
        }
        try require(try Data(contentsOf: input) == original, "Crop changed the oriented source file")
    }
}

test("Default smaller crops and enabled equal-size crops skip without output or source changes") {
    let input = try fixture("crop-skip.png")
    let original = try Data(contentsOf: input)
    let before = try directorySnapshot(output)
    var settings = ResizeSettings(); settings.format = .png; settings.preserveMetadata = false
    settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"
    settings.crop = CropSelection(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    for allowUpscaling in [false, true] {
        settings.allowUpscaling = allowUpscaling
        settings.mode = .longestEdge; settings.width = allowUpscaling ? 40 : 100
        let plan = try ResizeEngine.outputPlan(width: 80, height: 40, settings: settings)
        try require(plan.isCropped && plan.skipped && plan.width == 40 && plan.height == 20, "Unchanged crop bypassed the skip rule")
        try requireSkipped(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings), width: 40, height: 20)
        settings.mode = .percent
        for percent in allowUpscaling ? [100.0, 99.9, 100.1] : [100.0, 150.0] {
            settings.percent = percent
            try requireSkipped(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings), width: 40, height: 20)
        }
    }
    try require(try directorySnapshot(output) == before && Data(contentsOf: input) == original,
                "Equal-size crop created files or altered its source")
}

test("Cropping retains alpha and ICC while honoring metadata selection") {
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:04 12:00:00"]
    let transparent = try fixture("crop-alpha.tiff", type: "public.tiff", image: bitmap(width: 240, height: 120, transparent: true, p3: true),
                                  properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif])
    var settings = ResizeSettings(); settings.width = 78; settings.format = .png; settings.preserveMetadata = false
    settings.crop = CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7)
    let alphaOutput = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(transparent), to: output, settings: settings))
    try assertDimensions(alphaOutput, 78, 42)
    let rgba = try pixels(alphaOutput)
    try require(color(rgba, x: 0.2, y: 0.2)[3] == 0 && color(rgba, x: 0.8, y: 0.2)[3] == 255, "Crop flattened transparent pixels")
    try require(try properties(alphaOutput)[kCGImagePropertyProfileName] as? String == properties(transparent)[kCGImagePropertyProfileName] as? String,
                "Cropping/metadata stripping changed Display P3 ICC")
    try require(try properties(alphaOutput)[kCGImagePropertyGPSDictionary] == nil, "Cropped output ignored metadata stripping")
    let jpeg = try fixture("crop-metadata.jpg", type: "public.jpeg", image: bitmap(width: 240, height: 120, p3: true),
                           properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif])
    settings.format = .jpeg; settings.quality = 1
    for preserve in [true, false] {
        settings.preserveMetadata = preserve
        let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(jpeg), to: output, settings: settings))
        try assertDimensions(url, 78, 42)
        let resultGPS = try properties(url)[kCGImagePropertyGPSDictionary] as? NSDictionary
        try require(preserve ? (resultGPS?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 42.5 : resultGPS == nil,
                    "Cropped JPEG ignored metadata choice")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == properties(jpeg)[kCGImagePropertyProfileName] as? String,
                    "Cropped JPEG lost ICC")
    }
}

test("Only cropped exports remove stale subject and image-region coordinates") {
    let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:exif="http://ns.adobe.com/exif/1.0/"
          xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
          xmlns:MP="http://ns.microsoft.com/photo/1.2/"
          xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
          xmlns:ct="urn:resize-crop-tests">
          <exif:SubjectArea><rdf:Seq><rdf:li>96</rdf:li><rdf:li>48</rdf:li><rdf:li>32</rdf:li><rdf:li>24</rdf:li></rdf:Seq></exif:SubjectArea>
          <exif:SubjectLocation><rdf:Seq><rdf:li>40</rdf:li><rdf:li>20</rdf:li></rdf:Seq></exif:SubjectLocation>
          <mwg-rs:Regions rdf:parseType="Resource"><mwg-rs:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource"><mwg-rs:Name>Subject at 96,48</mwg-rs:Name></rdf:li></rdf:Bag></mwg-rs:RegionList></mwg-rs:Regions>
          <MP:RegionInfo rdf:parseType="Resource"><MP:Rectangle>0.4,0.4,0.2,0.2</MP:Rectangle></MP:RegionInfo>
          <Iptc4xmpExt:ImageRegion><rdf:Bag><rdf:li rdf:parseType="Resource"><Iptc4xmpExt:Name>Original image coordinates</Iptc4xmpExt:Name></rdf:li></rdf:Bag></Iptc4xmpExt:ImageRegion>
          <ct:Notes>Unrelated region commentary must survive</ct:Notes>
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    """
    guard let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) else {
        throw TestFailure("Could not create coordinate metadata fixture")
    }
    let input = work.appendingPathComponent("crop-coordinate-metadata.jpg")
    guard let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw TestFailure("Could not create coordinate metadata JPEG")
    }
    let date = "2026:10:04 12:00:00"
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date,
                               kCGImagePropertyExifSubjectArea: [96, 48, 32, 24],
                               kCGImagePropertyExifSubjectLocation: [40, 20]]
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    CGImageDestinationAddImageAndMetadata(destination, try bitmap(width: 240, height: 120, p3: true), metadata,
        [kCGImagePropertyExifDictionary: exif, kCGImagePropertyGPSDictionary: gps] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "Could not write coordinate metadata fixture")
    // ImageIO's JPEG writer silently omits SubjectLocation, even from an XMP
    // packet supplied by a caller. Inject the original valid packet as APP1 so
    // this incoming annotation exercises the reader/export path independently.
    let encoded = try Data(contentsOf: input)
    let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    let packet = xmpHeader + Data(xmp.utf8)
    let packetLength = packet.count + 2
    try require(packetLength < 65536, "Coordinate packet exceeds JPEG APP1 capacity")
    var incoming = Data([0xff, 0xd8, 0xff, 0xe1, UInt8(packetLength >> 8), UInt8(packetLength & 255)])
    incoming.append(packet)
    var position = 2
    while position < encoded.count {
        try require(position + 3 < encoded.count && encoded[position] == 0xff, "Fixture has invalid JPEG markers")
        let marker = encoded[position + 1]
        if marker == 0xda {
            incoming.append(encoded[position...])
            break
        }
        let segmentLength = Int(encoded[position + 2]) * 256 + Int(encoded[position + 3])
        let end = position + 2 + segmentLength
        try require(segmentLength >= 2 && end <= encoded.count, "Fixture has an invalid JPEG segment")
        let isXMP = marker == 0xe1 && encoded[(position + 4)..<end].starts(with: xmpHeader)
        if !isXMP { incoming.append(encoded[position..<end]) }
        position = end
    }
    try incoming.write(to: input)
    let original = try Data(contentsOf: input)
    let paths = ["exif:SubjectArea", "exif:SubjectLocation", "mwg-rs:Regions", "MP:RegionInfo", "Iptc4xmpExt:ImageRegion"]
    func readMetadata(_ url: URL) throws -> CGImageMetadata {
        guard let result = CGImageSourceCopyMetadataAtIndex(try source(url), 0, nil) else {
            throw TestFailure("Image metadata disappeared")
        }
        return result
    }
    let sourceMetadata = try readMetadata(input)
    for path in paths {
        try require(CGImageMetadataCopyTagWithPath(sourceMetadata, nil, path as CFString) != nil,
                    "Coordinate fixture did not encode \(path)")
    }
    let sourceExif = try properties(input)[kCGImagePropertyExifDictionary] as? NSDictionary
    try require(sourceExif?[kCGImagePropertyExifSubjectArea] != nil, "Coordinate fixture did not encode EXIF subject area")
    let profile = try properties(input)[kCGImagePropertyProfileName] as? String
    try require(profile != nil, "Coordinate fixture did not encode ICC")
    var settings = ResizeSettings(); settings.width = 120; settings.format = .jpeg; settings.quality = 1
    for cropped in [false, true] {
        settings.crop = cropped ? CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7) : nil
        let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        let resultMetadata = try readMetadata(url)
        for path in paths {
            let exists = CGImageMetadataCopyTagWithPath(resultMetadata, nil, path as CFString) != nil
            // SubjectLocation is omitted by native JPEG encoding regardless of
            // crop. The supported annotations must survive ordinary resizing.
            try require(path == "exif:SubjectLocation" ? !exists : exists != cropped,
                        "\(cropped ? "Cropped" : "Uncropped") output mishandled \(path)")
        }
        let resultProps = try properties(url)
        let resultExif = resultProps[kCGImagePropertyExifDictionary] as? NSDictionary
        try require((resultExif?[kCGImagePropertyExifSubjectArea] != nil) != cropped &&
                    resultExif?[kCGImagePropertyExifSubjectLocation] == nil,
                    "EXIF subject coordinates were not restricted to uncropped exports")
        try require(resultExif?[kCGImagePropertyExifDateTimeOriginal] as? String == date, "Crop cleanup removed capture date")
        let resultGPS = resultProps[kCGImagePropertyGPSDictionary] as? NSDictionary
        try require((resultGPS?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 42.5, "Crop cleanup removed GPS")
        try require(resultProps[kCGImagePropertyProfileName] as? String == profile, "Crop cleanup removed ICC")
        let notes = CGImageMetadataCopyTagWithPath(resultMetadata, nil, "ct:Notes" as CFString)
        try require(notes.flatMap { CGImageMetadataTagCopyValue($0) as? String } == "Unrelated region commentary must survive",
                    "Crop cleanup removed unrelated custom XMP")
    }
    try require(try Data(contentsOf: input) == original, "Metadata cleanup changed source annotations")
}

test("Cropped 16-bit outputs retain precision and profile with watermark drawn afterward") {
    let width = 600, height = 400
    let sample: [UInt16] = [32768, 20000, 40000, 65535]
    var words = [UInt16](); words.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) { words.append(contentsOf: sample) }
    let data = words.withUnsafeBytes { Data($0) }
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                        space: space, bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let input = try fixture("crop-sixteen.png", image: image)
    let original = try Data(contentsOf: input)
    let profile = try properties(input)[kCGImagePropertyProfileName] as? String
    var settings = ResizeSettings(); settings.width = 160
    settings.crop = CropSelection(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
    func readback(_ url: URL) throws -> [UInt16] {
        guard let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else { throw TestFailure("Cannot decode16-bit cropped output") }
        try require(decoded.width == 150 && decoded.height == 160 && decoded.bitsPerComponent == 16, "Cropped16-bit output has wrong dimensions or depth")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == profile && profile != nil, "Cropped16-bit output lost P3 profile")
        var values = [UInt16](repeating: 0, count: 150 * 160 * 4)
        try values.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 150, height: 160, bitsPerComponent: 16, bytesPerRow: 150 * 8,
                                          space: space, bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TestFailure("Cannot read precise cropped channels")
            }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 150, height: 160))
        }
        return values
    }
    var baseline = [UInt16]()
    for format in [OutputFormat.png, .tiff] {
        settings.format = format
        let values = try readback(outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)))
        let offset = (80 * 150 + 75) * 4
        try require((0..<4).allSatisfy { abs(Int(values[offset + $0]) - Int(sample[$0])) <= 8 }, "Crop reduced16-bit channel precision")
        if format == .png { baseline = values }
    }
    settings.format = .png; settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.watermarkStrength = 0.5
    let marked = try readback(outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)))
    var changed = 0
    for pixel in 0..<(150 * 160) {
        if (0..<4).contains(where: { abs(Int(marked[pixel * 4 + $0]) - Int(baseline[pixel * 4 + $0])) > 8 }) { changed += 1 }
    }
    try require(changed > 50 && changed < 150 * 160 / 2, "Watermark did not draw faint repeated strokes on the cropped output")
    try require(try Data(contentsOf: input) == original, "Cropping/watermarking changed16-bit source")
}

test("Layered PSD and TIFF crops use the visible flattened composite") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-crop"))
    let probes: [(Double, Double, [UInt8])] = [(0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
        (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])]
    for input in [documents.psd, documents.psd16, documents.tiff16] {
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.format = .png; settings.width = 32
        settings.crop = CropSelection(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
        let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        try assertDimensions(url, 32, 22)
        let rgba = try pixels(url)
        for (x, y, expected) in probes { try requireColor(color(rgba, x: x, y: y), expected, "Cropped layered composite \(input.lastPathComponent)", tolerance: 3) }
        try require(try Data(contentsOf: url).range(of: LayerFixtures.layerMarker) == nil, "Cropped output retained Photoshop layers")
        try require(try Data(contentsOf: input) == original, "Cropping changed editable layered source")
    }
}

test("Explicit PSD source previews preserve fitting-image composite alpha, depth and identity") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("source-preview"))
    let modes = try LayerFixtures.createColorModes(in: work.appendingPathComponent("source-preview-modes"))
    let gray = modes.first { $0.url.lastPathComponent.contains("gray-16") }!
    let rgbProbes: [(Double, Double, [UInt8])] = [(0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
        (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])]
    let before = try directorySnapshot(output)
    for input in [documents.psd, documents.psd16, gray.url] {
        let original = try Data(contentsOf: input)
        let pending = ImageItem.queued(input)
        for maximum in [1600, 40] {
            let (inspected, image) = try ResizeEngine.sourcePreview(pending, maxPixelDimension: maximum)
            try require(inspected.id == pending.id && inspected.width == 80 && inspected.height == 48 && inspected.isInspected,
                        "Source preview lost pending identity or changed source metadata dimensions")
            try require(image.width == (maximum == 40 ? 40 : 80) && image.height == (maximum == 40 ? 24 : 48),
                        "Source preview skipped fitting image, enlarged it, or ignored requested dimensions")
            try require(image.bitsPerComponent == (input == documents.psd ? 8 : 16), "Source preview lost native channel depth")
            let actual = try pixels(image)
            if input == gray.url {
                let reference = try pixels(gray.reference)
                for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                    try requireColor(color(actual, x: x, y: y), color(reference, x: x, y: y),
                                     "Gray16 preview differs from independent source-space control", tolerance: 3)
                }
            } else {
                for (x, y, expected) in rgbProbes {
                    try requireColor(color(actual, x: x, y: y), expected, "PSD source preview composite alpha", tolerance: 3)
                }
            }
        }
        try require(try Data(contentsOf: input) == original, "Source preview modified editable PSD")
    }
    try require(try directorySnapshot(output) == before, "Source preview generated exported files")
}

test("Original dimensions bypasses reduction skips and ignores inactive size controls") {
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .png
    settings.width = 0; settings.height = Int.min
    for percent in [Double.nan, .infinity, -.infinity, 0, -50] {
        settings.percent = percent
        for (width, height) in [(80, 40), (Int.max, Int.max - 1)] {
            let target = try ResizeEngine.targetSize(width: width, height: height, settings: settings)
            try require(target.width == width && target.height == height, "Original dimensions applied inactive size controls")
            let plan = try ResizeEngine.outputPlan(width: width, height: height, settings: settings)
            try require(!plan.skipped && plan.width == width && plan.height == height, "Original dimensions retained the fitting skip")
        }
    }
    settings.crop = CropSelection(x: 0.125, y: 0.1, width: 0.5, height: 0.5)
    let cropped = try ResizeEngine.outputPlan(width: 80, height: 40, settings: settings)
    try require(cropped.cropRect == CGRect(x: 10, y: 4, width: 40, height: 20) && cropped.width == 40 && cropped.height == 20 && !cropped.skipped,
                "Original dimensions did not export at the selected crop's pixel size")
    try requireThrows("Original dimensions accepted invalid source dimensions") {
        _ = try ResizeEngine.targetSize(width: 0, height: 40, settings: settings)
    }
    let input = try fixture("original-dimensions-validation.png")
    let before = try directorySnapshot(output)
    var invalid = settings; invalid.crop = CropSelection(width: 0)
    try requireThrows("Original dimensions ignored invalid active crop") {
        _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: invalid)
    }
    invalid = settings; invalid.crop = nil; invalid.quality = .nan
    try requireThrows("Original dimensions ignored invalid output quality") {
        _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: invalid)
    }
    invalid = settings; invalid.crop = nil; invalid.watermarkEnabled = true; invalid.watermarkText = "  "
    try requireThrows("Original dimensions ignored blank active watermark") {
        _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: invalid)
    }
    invalid.watermarkText = "SAMPLE"; invalid.watermarkStrength = .infinity
    try requireThrows("Original dimensions ignored invalid active watermark strength") {
        _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: invalid)
    }
    try require(try directorySnapshot(output) == before, "Invalid Original dimensions settings wrote output")
}

test("Original dimensions preserves every PNG pixel without scaling, including partial alpha") {
    let width = 71, height = 43
    for transparent in [false, true] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((x * 47 + y * 13) % 256)
                bytes[offset + 1] = UInt8((x * 29 + y * 71) % 256)
                bytes[offset + 2] = UInt8((x * 89 + y * 19) % 256)
                bytes[offset + 3] = 255
                if transparent && x > width / 2 {
                    bytes[offset] = 255; bytes[offset + 1] = 0; bytes[offset + 2] = 255
                    bytes[offset + 3] = x > width * 3 / 4 ? 0 : 128
                }
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: transparent ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let input = try fixture("original-pixels-\(transparent).png", image: image)
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .png
        settings.width = 1; settings.height = 1; settings.percent = 1
        settings.preserveMetadata = !transparent
        let result = try ResizeEngine.resize(ImageItem.queued(input), to: output, settings: settings)
        let url = try outputURL(result)
        let expected = try pixels(input), actual = try pixels(url)
        try require(!result.skipped && actual.0 == width && actual.1 == height && actual.2 == expected.2,
                    "Original dimensions resampled PNG pixels or changed alpha")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == properties(input)[kCGImagePropertyProfileName] as? String,
                    "Original dimensions lost ICC when encoding PNG")
        try require(try Data(contentsOf: input) == original, "Original dimensions changed source PNG")
    }
}

test("Original dimensions retains fine 16-bit pixels and alpha in PNG and TIFF") {
    let width = 31, height = 19
    var words = [UInt16](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            words[offset] = UInt16(16385 + (x * 17 + y * 19) % 1000)
            words[offset + 1] = UInt16(32769 + (x * 31 + y * 13) % 1000)
            words[offset + 2] = UInt16(49153 + (x * 41 + y * 7) % 1000)
            words[offset + 3] = 65535
            if x > width / 2 {
                words[offset] = 65535; words[offset + 1] = 0; words[offset + 2] = 32768
                words[offset + 3] = x > width * 3 / 4 ? 0 : 32768
            }
        }
    }
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let data = words.withUnsafeBytes { Data($0) }
    let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                        space: space, bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let input = try fixture("original-fine16.png", image: image)
    let original = try Data(contentsOf: input)
    func read16(_ url: URL) throws -> [UInt16] {
        guard let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil) else { throw TestFailure("Cannot decode Original dimensions16-bit output") }
        try require(decoded.width == width && decoded.height == height && decoded.bitsPerComponent == 16,
                    "Original dimensions changed16-bit depth or pixel dimensions")
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                          bytesPerRow: width * 8, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TestFailure("Cannot inspect Original dimensions16-bit pixels")
            }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
    let expected = try read16(input)
    for format in [OutputFormat.png, .tiff] {
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = format; settings.preserveMetadata = false
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(result)
        let actual = try read16(url)
        try require(!result.skipped && zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                    "Original dimensions changed fine16-bit pixels or transparency")
        try require(try properties(url)[kCGImagePropertyProfileName] as? String == properties(input)[kCGImagePropertyProfileName] as? String,
                    "Original dimensions lost16-bit ICC")
    }
    try require(try Data(contentsOf: input) == original, "Original dimensions modified16-bit source")
}

test("Original dimensions exports selected formats and applies watermark and metadata choices") {
    let date = "2026:10:04 12:00:00"
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    let input = try fixture("original-options.tiff", type: "public.tiff", image: bitmap(width: 600, height: 400, p3: true),
                            properties: [kCGImagePropertyGPSDictionary: gps,
                                         kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]])
    let original = try Data(contentsOf: input)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.quality = 1
    settings.width = 0; settings.height = -1; settings.percent = .nan
    let formats: [(OutputFormat, String)] = [(.original, "public.tiff"), (.jpeg, "public.jpeg"), (.png, "public.png"),
                                            (.tiff, "public.tiff"), (.heic, "public.heic")]
    for (format, identifier) in formats {
        settings.format = format
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(result)
        try require(!result.skipped && result.width == 600 && result.height == 400 && result.outputBytes > 0,
                    "Original dimensions skipped or reduced \(format) export")
        try assertDimensions(url, 600, 400)
        try require(CGImageSourceGetType(try source(url)) as String? == identifier, "Original dimensions ignored selected \(format)")
        let resultProps = try properties(url)
        let resultGPS = resultProps[kCGImagePropertyGPSDictionary] as? NSDictionary
        try require((resultGPS?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 42.5,
                    "Original dimensions lost GPS in \(format)")
    }
    settings.format = .png; settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.watermarkStrength = 0.5
    let baseline = try pixels(input)
    for preserve in [false, true] {
        settings.preserveMetadata = preserve
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(result)
        let changed = try changedPixels(baseline, pixels(url))
        let changedCount = changed.reduce(0) { $0 + Int($1) }
        try require(!result.skipped && changedCount > 50 && changedCount < baseline.0 * baseline.1 / 2,
                    "Original dimensions failed to draw bounded watermark outlines")
        let resultProps = try properties(url)
        let resultGPS = resultProps[kCGImagePropertyGPSDictionary] as? NSDictionary
        let resultExif = resultProps[kCGImagePropertyExifDictionary] as? NSDictionary
        try require(preserve ? (resultGPS?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 42.5 : resultGPS == nil,
                    "Original dimensions ignored metadata choice for GPS")
        try require(preserve ? resultExif?[kCGImagePropertyExifDateTimeOriginal] as? String == date : resultExif?[kCGImagePropertyExifDateTimeOriginal] == nil,
                    "Original dimensions ignored metadata choice for capture date")
        try require(resultProps[kCGImagePropertyProfileName] as? String == properties(input)[kCGImagePropertyProfileName] as? String,
                    "Original dimensions lost watermark output ICC")
    }
    try require(try Data(contentsOf: input) == original, "Original dimensions options changed source")
}

test("Original dimensions normalizes every EXIF orientation and exports exact crop dimensions") {
    let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                    [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
    let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    let probes = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
    for orientation in 1...8 {
        let input = try fixture("original-orientation-\(orientation).tiff", type: "public.tiff",
                                image: bitmap(width: 80, height: 40), properties: [kCGImagePropertyOrientation: orientation])
        let original = try Data(contentsOf: input)
        let item = try ResizeEngine.inspect(input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .png
        for cropped in [false, true] {
            settings.crop = cropped ? CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7) : nil
            let width = cropped ? (orientation >= 5 ? 26 : 52) : item.width
            let height = cropped ? (orientation >= 5 ? 56 : 28) : item.height
            let result = try ResizeEngine.resize(item, to: output, settings: settings)
            let url = try outputURL(result)
            try require(!result.skipped && result.width == width && result.height == height, "Original dimensions skipped or scaled oriented crop")
            let rgba = try pixels(url)
            try require(rgba.0 == width && rgba.1 == height, "Original dimensions encoded wrong oriented crop size")
            for (index, probe) in probes.enumerated() {
                try requireColor(color(rgba, x: probe.0, y: probe.1), colors[expected[orientation - 1][index]],
                                 "Original dimensions crop chose incorrect EXIF\(orientation) pixels", tolerance: 1)
            }
            let outputOrientation = (try properties(url)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            try require(outputOrientation == 1, "Original dimensions retained EXIF rotation after normalizing pixels")
        }
        try require(try Data(contentsOf: input) == original, "Original dimensions changed oriented source")
    }
}

test("Original dimensions flattens layered PSD and TIFF at full composite resolution") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-original-dimensions"))
    let probes: [(Double, Double, [UInt8])] = [(0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
                                             (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])]
    for input in [documents.psd, documents.psd16, documents.tiff, documents.tiff16] {
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .png
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(result)
        let rgba = try pixels(url)
        try require(!result.skipped && rgba.0 == 80 && rgba.1 == 48, "Original dimensions skipped or scaled layered input")
        for (x, y, expected) in probes {
            try requireColor(color(rgba, x: x, y: y), expected, "Original dimensions layered visible composite", tolerance: 3)
        }
        let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil)
        try require(decoded?.bitsPerComponent == (input == documents.psd16 || input == documents.tiff16 ? 16 : 8),
                    "Original dimensions changed layered channel depth")
        let encoded = try Data(contentsOf: url)
        try require(encoded.range(of: LayerFixtures.layerMarker) == nil && !LayerFixtures.tiffTags(encoded).contains(37724),
                    "Original dimensions output retained editable layers")
        let adobe = try properties(url)["{8BIM}"] as? NSDictionary
        try require(adobe?["LayerNames"] == nil, "Original dimensions kept layer metadata")
        try require(try Data(contentsOf: input) == original, "Original dimensions changed layered source")
    }
}

test("Original dimensions exports same-folder and duplicate basenames without overwriting") {
    let first = try fixture("original-collisions/first/same.png")
    let second = try fixture("original-collisions/second/same.png", image: bitmap(transparent: true))
    let folder = first.deletingLastPathComponent()
    let existing = folder.appendingPathComponent("same-2.png")
    try Data("Existing file is not available for overwrite".utf8).write(to: existing)
    let before = try directorySnapshot(folder)
    let secondBytes = try Data(contentsOf: second)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .original
    var created = Set<URL>()
    for input in [first, second, first] {
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: folder, settings: settings)
        let url = try outputURL(result)
        try require(!result.skipped && url != first && url != second && url != existing && created.insert(url).inserted,
                    "Original dimensions overwrote a source, existing output, or another export")
        try assertDimensions(url, 80, 40)
    }
    let after = try directorySnapshot(folder)
    try require(after.count == before.count + 3, "Original dimensions did not create exactly three collision-safe outputs")
    for (name, hash) in before { try require(after[name] == hash, "Original dimensions changed an existing same-folder file") }
    try require(try Data(contentsOf: second) == secondBytes, "Original dimensions overwrote duplicate input from another folder")
}

test("Web quality validates only its active preset and ignores ordinary quality") {
    let input = try fixture("web-quality.png")
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web; settings.quality = .nan
    let before = try directorySnapshot(output)
    for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
        settings.webQuality = invalid
        try requireThrows("Web preset accepted invalid active quality") {
            _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        }
    }
    try require(try directorySnapshot(output) == before, "Invalid web quality wrote output")
    settings.webQuality = 0.75
    let web = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    try require(!web.skipped, "Inactive ordinary quality blocked web export")
    try assertDimensions(outputURL(web), 80, 40)
    settings.format = .png; settings.quality = 0.9; settings.webQuality = .nan
    let normal = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
    try require(!normal.skipped, "Inactive web quality blocked an ordinary format")
    try assertDimensions(outputURL(normal), 80, 40)
}

test("Opaque web exports choose the smallest native candidate and compress textured images") {
    let graphicWidth = 512, graphicHeight = 320
    let palette: [[UInt8]] = [[0, 0, 0, 255], [255, 255, 255, 255], [35, 92, 210, 255], [250, 191, 24, 255]]
    var graphicBytes = [UInt8](repeating: 0, count: graphicWidth * graphicHeight * 4)
    for y in 0..<graphicHeight { for x in 0..<graphicWidth {
        let sample = palette[(x / 7 + y / 11) % palette.count]
        let offset = (y * graphicWidth + x) * 4
        for channel in 0..<4 { graphicBytes[offset + channel] = sample[channel] }
    } }
    let graphic = CGImage(width: graphicWidth, height: graphicHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: graphicWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                          provider: CGDataProvider(data: Data(graphicBytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let cases = [("texture", try texturedBitmap()), ("graphic", graphic)]
    for (name, image) in cases {
        let input = try fixture("web-\(name).png", image: image)
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web; settings.webQuality = 0.75
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(result)
        let encoded = try Data(contentsOf: url)
        let actualType = CGImageSourceGetType(try source(url)) as String?
        let candidates = try webEncodingCandidates(image, quality: 0.75)
        let minimum = candidates.map { $0.1.count }.min()!
        let winnerTypes = Set(candidates.filter { $0.1.count == minimum }.map { $0.0 })
        try require(encoded.count == minimum && actualType.map { winnerTypes.contains($0) } == true,
                    "Web preset failed to choose the smallest equivalent native encode: web\(encoded.count), candidates\(candidates.map { $0.1.count })")
        print("Web \(name) candidates: \(candidates.map { $0.1.count }); selected \(encoded.count) bytes \(actualType ?? "unknown")")
        try require(result.outputBytes == Int64(encoded.count) && !result.skipped, "Web result did not report selected candidate size")
        try assertDimensions(url, image.width, image.height)
        try require(actualType == (name == "texture" ? "public.jpeg" : "public.png"),
                    "Web preset did not distinguish textured images from lossless graphics")
        if name == "graphic" {
            let expected = try pixels(input), actual = try pixels(url)
            try require(expected.2 == actual.2, "Web graphic PNG lost exact opaque pixels")
        } else {
            settings.format = .jpeg; settings.quality = 0.9; settings.preserveMetadata = false
            let normal = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
            let normalBytes = try Data(contentsOf: normal).count
            try require(encoded.count < normalBytes, "Web75 did not reduce the textured fixture versus ordinaryJPEG90")
            print("Web texture \(image.width)×\(image.height): JPEG90 \(normalBytes) bytes; web75 \(encoded.count) bytes; native candidates \(candidates.map { $0.1.count })")
        }
        try require(try Data(contentsOf: input) == original, "Web compression changed source")
    }
}

test("Web output selection uses final alpha after cropping and watermarking") {
    let width = 160, height = 120
    let image = try texturedBitmap(width: width, height: height)
    var bytes = try pixels(image).2
    for y in 0..<height { for x in 0..<width {
        if x < 20 || x >= width - 20 || y < 15 || y >= height - 15 { bytes[(y * width + x) * 4 + 3] = 0 }
    } }
    let bordered = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                           provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let input = try fixture("web-transparent-border.png", image: bordered)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web
    let full = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
    try require(CGImageSourceGetType(try source(full)) as String? == "public.png", "Web discarded a transparent border")
    let rgba = try pixels(full)
    try require(color(rgba, x: 0.05, y: 0.05)[3] == 0 && color(rgba, x: 0.5, y: 0.5)[3] == 255,
                "Web PNG changed clear or opaque alpha")
    settings.crop = CropSelection(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let cropped = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
    try assertDimensions(cropped, 80, 60)
    try require(CGImageSourceGetType(try source(cropped)) as String? == "public.jpeg", "Opaque textured crop kept a removed transparent border")
    settings.crop = nil; settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.watermarkStrength = 0.5
    let marked = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
    try require(CGImageSourceGetType(try source(marked)) as String? == "public.png", "Web watermark flattened transparent background")
    let markedPixels = try pixels(marked)
    let changed = try changedPixels(rgba, markedPixels)
    try require(changed.contains(1), "Web output lost the watermark")
    try require(stride(from: 3, to: markedPixels.2.count, by: 4).contains { markedPixels.2[$0] > 0 && markedPixels.2[$0] < 255 },
                "Web output lost partial-alpha watermark outlines")
}

test("Web converts P3 and16-bit pixels to8-bit sRGB while stripping all source metadata") {
    let width = 120, height = 80
    let date = "2026:10:05 12:00:00"
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:ct="urn:resize-web-tests"><ct:Notes>Private source annotation</ct:Notes></rdf:Description></rdf:RDF></x:xmpmeta>
    """
    let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData)!
    for depth in [8, 16] {
        var words = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            words[offset] = 40000; words[offset + 1] = 18000; words[offset + 2] = 29000
            words[offset + 3] = x < width / 2 ? 65535 : 32768
        } }
        let data = depth == 16 ? words.withUnsafeBytes { Data($0) } : Data(words.map { UInt8($0 / 257) })
        let bitmapInfo: CGBitmapInfo = depth == 16 ? [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)] : CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let image = CGImage(width: width, height: height, bitsPerComponent: depth, bitsPerPixel: depth * 4,
                            bytesPerRow: width * depth / 2, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: bitmapInfo,
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let input = work.appendingPathComponent("web-color-\(depth).tiff")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(destination, image, metadata,
            [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Cannot encode web color/metadata fixture")
        let original = try Data(contentsOf: input)
        let sourceMetadata = CGImageSourceCopyMetadataAtIndex(try source(input), 0, nil)!
        try require(CGImageMetadataCopyTagWithPath(sourceMetadata, nil, "ct:Notes" as CFString) != nil, "Web fixture lacks custom XMP")
        try require(try properties(input)[kCGImagePropertyGPSDictionary] != nil, "Web fixture lacks GPS")
        let expected = try pixels(input)
        for preserve in [false, true] {
            var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web; settings.preserveMetadata = preserve
            let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
            let resultProps = try properties(url)
            let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil)!
            try require(CGImageSourceGetType(try source(url)) as String? == "public.png" && decoded.bitsPerComponent == 8,
                        "Web alpha output did not become8-bit PNG")
            try require(decoded.colorSpace?.name as String? == CGColorSpace.sRGB as String && resultProps[kCGImagePropertyProfileName] != nil,
                        "Web color was not encoded with embedded sRGB")
            let actual = try pixels(url)
            for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                try requireColor(color(actual, x: x, y: y), color(expected, x: x, y: y), "Web P3 conversion/reference alpha", tolerance: 3)
            }
            try require(resultProps[kCGImagePropertyGPSDictionary] == nil && resultProps[kCGImageProperty8BIMDictionary] == nil,
                        "Web export retained GPS or layer metadata")
            let exif = resultProps[kCGImagePropertyExifDictionary] as? NSDictionary
            try require(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "Web export retained capture date")
            if let resultMetadata = CGImageSourceCopyMetadataAtIndex(try source(url), 0, nil) {
                try require(CGImageMetadataCopyTagWithPath(resultMetadata, nil, "ct:Notes" as CFString) == nil, "Web export retained custom XMP")
            }
        }
        try require(try Data(contentsOf: input) == original, "Web conversion or metadata stripping changed source")
    }
}

test("Web retains every resize mode, crop dimensions, orientation and watermark") {
    let input = try fixture("web-modes.tiff", type: "public.tiff", image: bitmap(width: 240, height: 120),
                            properties: [kCGImagePropertyOrientation: 6])
    let item = try ResizeEngine.inspect(input)
    let cases: [(ResizeMode, Int, Int, Double, Int, Int)] = [(.longestEdge, 84, 1, 1, 39, 84),
        (.fit, 30, 50, 1, 23, 50), (.width, 20, 1, 1, 20, 43), (.height, 1, 70, 1, 33, 70),
        (.percent, 1, 1, 50, 39, 84), (.originalDimensions, 0, -1, .nan, 78, 168)]
    for (mode, width, height, percent, expectedWidth, expectedHeight) in cases {
        var settings = ResizeSettings(); settings.format = .web; settings.mode = mode
        settings.width = width; settings.height = height; settings.percent = percent
        settings.crop = CropSelection(x: 0.2, y: 0.15, width: 0.65, height: 0.7)
        let url = try outputURL(ResizeEngine.resize(item, to: output, settings: settings))
        try assertDimensions(url, expectedWidth, expectedHeight)
        try requireColor(color(try pixels(url), x: 0.2, y: 0.2), [0, 0, 255, 255], "Web crop/orientation pixel position", tolerance: 8)
    }
    let watermarkInput = try fixture("web-watermark.png", image: solidBitmap(width: 600, height: 400, white: 1))
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web
    settings.crop = CropSelection(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let plain = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(watermarkInput), to: output, settings: settings))
    settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.watermarkStrength = 0.5
    let marked = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(watermarkInput), to: output, settings: settings))
    try assertDimensions(marked, 480, 320)
    let changed = try changedPixels(pixels(plain), pixels(marked)).filter { $0 != 0 }.count
    try require(changed > 50 && changed < 480 * 320 / 2, "Web crop export ignored or broadly filled watermark text")
}

test("Web layered exports preserve the unmatted visible composite as8-bit sRGB PNG") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("layered-web"))
    let colorModes = try LayerFixtures.createColorModes(in: work.appendingPathComponent("layered-web-modes"))
    let probes: [(Double, Double, [UInt8])] = [(0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
                                             (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])]
    for input in [documents.psd, documents.psd16, documents.tiff, documents.tiff16] + colorModes.map({ $0.url }) {
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web; settings.preserveMetadata = true
        let url = try outputURL(ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings))
        let decoded = CGImageSourceCreateImageAtIndex(try source(url), 0, nil)!
        try require(CGImageSourceGetType(try source(url)) as String? == "public.png" && decoded.bitsPerComponent == 8,
                    "Web layered alpha output used incorrect type/depth")
        try require(decoded.colorSpace?.name as String? == CGColorSpace.sRGB as String, "Web layered output retained a non-sRGB profile")
        let actual = try pixels(url)
        if let document = colorModes.first(where: { $0.url == input }) {
            let reference = try pixels(document.reference)
            for (x, y, _) in probes {
                try requireColor(color(actual, x: x, y: y), color(reference, x: x, y: y), "Web non-RGB Photoshop composite", tolerance: 3)
            }
        } else {
            for (x, y, expected) in probes {
                try requireColor(color(actual, x: x, y: y), expected, "Web Photoshop composite white-matte removal", tolerance: 3)
            }
        }
        try require(try Data(contentsOf: url).range(of: LayerFixtures.layerMarker) == nil, "Web export retained layer bytes")
        try require(try properties(url)[kCGImageProperty8BIMDictionary] == nil, "Web export retained layer metadata")
        try require(try Data(contentsOf: input) == original, "Web flattening changed editable source")
    }
}

test("Web auto-extension output protects existing files and duplicate source basenames") {
    let first = try fixture("web-collisions/first/same.png", image: texturedBitmap(width: 320, height: 200))
    let second = try fixture("web-collisions/second/same.png", image: bitmap(width: 320, height: 200, transparent: true))
    let folder = first.deletingLastPathComponent()
    try Data("Existing JPEG must survive".utf8).write(to: folder.appendingPathComponent("same.jpg"))
    let before = try directorySnapshot(folder)
    let secondBytes = try Data(contentsOf: second)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web
    var created = Set<URL>()
    for input in [first, second, first] {
        let result = try ResizeEngine.resize(ResizeEngine.inspect(input), to: folder, settings: settings)
        let url = try outputURL(result)
        try require(!result.skipped && url != first && url != second && created.insert(url).inserted,
                    "Web auto-format selection overwrote a source or duplicate output")
        try require(url.pathExtension.lowercased() == (input == second ? "png" : "jpg"), "Web selected a misleading output extension")
        try assertDimensions(url, 320, 200)
    }
    let after = try directorySnapshot(folder)
    try require(after.count == before.count + 3, "Web left candidate files or failed to publish three outputs")
    for (name, hash) in before { try require(after[name] == hash, "Web overwrote an existing same-folder file") }
    try require(try Data(contentsOf: second) == secondBytes, "Web changed a source from another folder")
}

test("Enlargement estimates match actual bytes across all formats, crop, watermark and metadata choices") {
    let width = 320, height = 200
    var words = [UInt16](repeating: 0, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let offset = (y * width + x) * 4
        words[offset] = UInt16(23000 + x * 37); words[offset + 1] = UInt16(17000 + y * 47)
        words[offset + 2] = 40000; words[offset + 3] = x < width / 2 ? 65535 : 32768
    } }
    let data = words.withUnsafeBytes { Data($0) }
    let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!,
                        bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 42.5, kCGImagePropertyGPSLatitudeRef: "N"]
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 12:00:00"]
    let input = try fixture("estimate-options.tiff", type: "public.tiff", image: image,
                            properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif])
    let original = try Data(contentsOf: input)
    let item = ImageItem.queued(input)
    let temporary = work.appendingPathComponent("estimate-options-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("Caller-owned file must remain".utf8).write(to: temporary.appendingPathComponent("keep.txt"))
    let before = try directorySnapshot(temporary)
    for format in OutputFormat.allCases {
        for preserve in [false, true] {
            var settings = ResizeSettings(); settings.width = 384; settings.format = format; settings.preserveMetadata = preserve
            settings.allowUpscaling = true
            settings.crop = CropSelection(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
            settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.watermarkStrength = 0.4
            var callbacks = [ImageItem]()
            let estimate = try ResizeEngine.estimateOutput(item, settings: settings, onInspect: { callbacks.append($0) }, temporaryRoot: temporary)
            try require(callbacks.count == 1 && callbacks[0].id == item.id && callbacks[0].width == width && callbacks[0].height == height,
                        "Estimate inspection lost stable identity or source dimensions")
            try require(try directorySnapshot(temporary) == before, "Estimate left temporary files or removed caller-owned files")
            let actual = try ResizeEngine.resize(item, to: output, settings: settings)
            let url = try outputURL(actual)
            try require(!estimate.skipped && estimate.width == 384 && estimate.height == 210 &&
                        estimate.width == actual.width && estimate.height == actual.height && estimate.outputBytes == actual.outputBytes,
                        "\(format) estimate did not match exact cropped/watermarked output bytes: estimated\(estimate.outputBytes), actual\(actual.outputBytes)")
            try require(estimate.formatExtension == url.pathExtension && estimate.outputBytes == Int64(try Data(contentsOf: url).count),
                        "Estimate predicted the wrong output extension or file length")
        }
    }
    try require(try Data(contentsOf: input) == original, "Trial estimates changed16-bit source or metadata")
}

test("Original dimensions estimates include web auto-selection and transparent PSD fallback") {
    let documents = try LayerFixtures.create(in: work.appendingPathComponent("estimate-layered"))
    let opaque = try fixture("estimate-web-texture.png", image: texturedBitmap(width: 320, height: 200))
    let alpha = try fixture("estimate-web-alpha.png", image: bitmap(transparent: true))
    let temporary = work.appendingPathComponent("estimate-original-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    for (input, format, expectedExtension) in [(opaque, OutputFormat.web, "jpg"), (alpha, .web, "png"),
                                              (documents.psd, .original, "png"), (documents.psd16, .original, "png")] {
        let original = try Data(contentsOf: input)
        var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = format
        let estimate = try ResizeEngine.estimateOutput(ImageItem.queued(input), settings: settings, temporaryRoot: temporary)
        let actual = try ResizeEngine.resize(ResizeEngine.inspect(input), to: output, settings: settings)
        let url = try outputURL(actual)
        try require(!estimate.skipped && estimate.outputBytes > 0 && estimate.outputBytes == actual.outputBytes &&
                    estimate.width == actual.width && estimate.height == actual.height && estimate.formatExtension == expectedExtension &&
                    url.pathExtension == expectedExtension, "Original dimensions estimate missed actual web format or PSD fallback")
        try require(try fileManager.contentsOfDirectory(atPath: temporary.path).isEmpty, "Original dimensions estimate left an encoded trial")
        try require(try Data(contentsOf: input) == original, "Original dimensions estimate changed source")
    }
}

test("Default smaller and enabled equal-size crop estimates report zero bytes without a destination format") {
    let input = try fixture("estimate-skip.png")
    let original = try Data(contentsOf: input)
    let temporary = work.appendingPathComponent("estimate-skip-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    let beforeOutput = try directorySnapshot(output)
    for allowUpscaling in [false, true] {
      for mode in ResizeMode.allCases where mode != .originalDimensions {
        for format in OutputFormat.allCases {
            for cropped in [false, true] {
                var settings = ResizeSettings(); settings.mode = mode; settings.allowUpscaling = allowUpscaling
                settings.width = allowUpscaling ? (cropped ? 40 : 80) : 1600
                settings.height = allowUpscaling ? (cropped ? 20 : 40) : 1600
                settings.percent = allowUpscaling ? 100 : 150
                settings.format = format; settings.watermarkEnabled = true; settings.watermarkText = "SAMPLE"; settings.preserveMetadata = false
                settings.crop = cropped ? CropSelection(x: 0.25, y: 0.25, width: 0.5, height: 0.5) : nil
                let estimate = try ResizeEngine.estimateOutput(ImageItem.queued(input), settings: settings, temporaryRoot: temporary)
                try require(estimate.skipped && estimate.outputBytes == 0 && estimate.formatExtension == nil &&
                            estimate.width == (cropped ? 40 : 80) && estimate.height == (cropped ? 20 : 40),
                            "Equal-size estimate was unavailable or predicted a conversion instead of zero bytes")
            }
        }
      }
    }
    try require(try directorySnapshot(output) == beforeOutput && fileManager.contentsOfDirectory(atPath: temporary.path).isEmpty,
                "Skipped estimates wrote files")
    try require(try Data(contentsOf: input) == original, "Skipped estimates changed source")
}

test("Estimates refresh stale metadata and clean temporary work after invalid inputs") {
    let input = try fixture("estimate-changing.png")
    let stale = try ResizeEngine.inspect(input)
    try fixture("estimate-changing.png", image: bitmap(width: 160, height: 96, transparent: true))
    let original = try Data(contentsOf: input)
    let temporary = work.appendingPathComponent("estimate-failures-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("Caller-owned marker".utf8).write(to: temporary.appendingPathComponent("keep.txt"))
    let before = try directorySnapshot(temporary)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .png
    var callbacks = [ImageItem]()
    let estimate = try ResizeEngine.estimateOutput(stale, settings: settings, onInspect: { callbacks.append($0) }, temporaryRoot: temporary)
    try require(estimate.width == 160 && estimate.height == 96 && callbacks.count == 1 && callbacks[0].id == stale.id &&
                callbacks[0].width == 160 && callbacks[0].height == 96, "Estimate trusted stale imported dimensions")
    let actual = try ResizeEngine.resize(stale, to: output, settings: settings)
    try require(estimate.outputBytes == actual.outputBytes, "Refreshed estimate did not match fresh export")
    let corrupt = work.appendingPathComponent("estimate-corrupt.jpg")
    try Data("Invalid image bytes".utf8).write(to: corrupt)
    var failedCallbacks = 0
    try requireThrows("Estimate accepted a corrupt image as zero-sized output") {
        _ = try ResizeEngine.estimateOutput(ImageItem.queued(corrupt), settings: settings,
            onInspect: { _ in failedCallbacks += 1 }, temporaryRoot: temporary)
    }
    try require(failedCallbacks == 0, "Failed estimate reported valid metadata")
    settings.quality = .nan
    try requireThrows("Estimate ignored invalid active output settings") {
        _ = try ResizeEngine.estimateOutput(stale, settings: settings, temporaryRoot: temporary)
    }
    try require(try directorySnapshot(temporary) == before, "Invalid estimate leaked work or removed caller-owned data")
    try require(try Data(contentsOf: input) == original, "Estimate refresh/failure changed source")
}

test("Estimate cancellation before and after inspection preserves sources and cleans work") {
    let temporary = work.appendingPathComponent("estimate-early-cancel-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("Caller-owned marker".utf8).write(to: temporary.appendingPathComponent("keep.txt"))
    let before = try directorySnapshot(temporary)
    let missing = ImageItem.queued(work.appendingPathComponent("cancelled-missing-source.png"))
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web
    var callbacks = 0
    try requireCancellation("Pre-cancelled estimate read or encoded its missing source") {
        _ = try ResizeEngine.estimateOutput(missing, settings: settings, cancelled: { true },
            onInspect: { _ in callbacks += 1 }, temporaryRoot: temporary)
    }
    try require(callbacks == 0, "Pre-cancelled estimate inspected its source")
    let input = try fixture("estimate-after-inspect.png")
    let original = try Data(contentsOf: input)
    var cancelled = false
    try requireCancellation("Estimate ignored cancellation after inspection") {
        _ = try ResizeEngine.estimateOutput(ImageItem.queued(input), settings: settings, cancelled: { cancelled },
            onInspect: { _ in callbacks += 1; cancelled = true }, temporaryRoot: temporary)
    }
    try require(callbacks == 1, "After-inspection cancellation bypassed or repeated metadata callback")
    try require(try directorySnapshot(temporary) == before, "Cancelled estimate leaked temporary work")
    try require(try Data(contentsOf: input) == original, "Cancelled estimate changed source")
}

test("Cancellation after encoding removes estimate and export candidates without publishing") {
    let input = try fixture("estimate-encoded-cancel.png", image: texturedBitmap(width: 320, height: 200))
    let original = try Data(contentsOf: input)
    let temporary = work.appendingPathComponent("estimate-encoded-cancel-temp", isDirectory: true)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    var settings = ResizeSettings(); settings.mode = .originalDimensions; settings.format = .web
    var trialWritten = false
    try requireCancellation("Estimate ignored cancellation after writing a codec candidate") {
        _ = try ResizeEngine.estimateOutput(ImageItem.queued(input), settings: settings, cancelled: {
            if let enumerator = fileManager.enumerator(at: temporary, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let file as URL in enumerator {
                    if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                       values.isRegularFile == true, (values.fileSize ?? 0) > 0 { trialWritten = true; return true }
                }
            }
            return false
        }, temporaryRoot: temporary)
    }
    try require(trialWritten && (try fileManager.contentsOfDirectory(atPath: temporary.path)).isEmpty,
                "Estimate cancellation was not exercised after encoding or leaked its candidate")
    let destination = work.appendingPathComponent("export-encoded-cancel", isDirectory: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("Existing output must survive".utf8).write(to: destination.appendingPathComponent("keep.txt"))
    let before = try directorySnapshot(destination)
    var exportWritten = false
    try requireCancellation("Export swallowed cancellation after writing a web candidate") {
        _ = try ResizeEngine.resize(ResizeEngine.inspect(input), to: destination, settings: settings, cancelled: {
            for file in (try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                if file.lastPathComponent.hasPrefix(".resize-"),
                   let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 {
                    exportWritten = true; return true
                }
            }
            return false
        })
    }
    try require(exportWritten && (try directorySnapshot(destination)) == before,
                "Cancelled export published output, leaked candidates or changed existing files")
    try require(try Data(contentsOf: input) == original, "Encoded cancellation changed source")
}

test("Estimate totals distinguish pending, unavailable and skipped results and recover after overflow") {
    let store = OutputEstimateStore()
    let ids = (0..<4).map { _ in UUID() }
    store.append(ids + [ids[0]])
    try require(store.count == 4 && store.pendingCount == 4 && store.completedCount == 0 && store.totalBytes == 0,
                "Estimate membership duplicated an input or treated pending values as completed")
    func ready(_ bytes: Int64, skipped: Bool = false) -> OutputEstimateValue {
        .ready(OutputSizeEstimate(width: 10, height: 5, outputBytes: bytes, skipped: skipped, formatExtension: skipped ? nil : "png"))
    }
    let generation = store.generation
    try require(store.record(ready(100), for: ids[0], generation: generation) &&
                store.record(ready(0, skipped: true), for: ids[1], generation: generation) &&
                store.record(.unavailable("Cannot decode"), for: ids[2], generation: generation), "Estimate ledger rejected live results")
    try require(store.totalBytes == 100 && store.completedCount == 3 && store.pendingCount == 1 && store.failureCount == 1 && store.skippedCount == 1,
                "Estimate totals confused pending, failed and zero-byte skipped results")
    store.record(ready(250), for: ids[0], generation: generation)
    store.record(ready(40), for: ids[2], generation: generation)
    store.record(.unavailable("Output unavailable"), for: ids[1], generation: generation)
    try require(store.totalBytes == 290 && store.completedCount == 3 && store.failureCount == 1 && store.skippedCount == 0,
                "Repeated completions were double-counted or left stale counters")
    store.remove([ids[2]])
    try require(store.totalBytes == 250 && store.count == 3 && store.completedCount == 2 && store.value(for: ids[2]) == nil,
                "Removing a ready input left its estimated bytes")
    store.reset()
    let next = store.generation
    store.record(ready(Int64.max), for: ids[0], generation: next)
    store.record(ready(150), for: ids[3], generation: next)
    try require(store.totalBytes == Int64.max, "Unrepresentable estimate total overflowed")
    store.record(ready(100), for: ids[0], generation: next)
    try require(store.totalBytes == 250, "Estimate total did not recover after replacing an overflow-sized value")
    store.remove([ids[0]])
    try require(store.totalBytes == 150 && store.completedCount == 1 && store.pendingCount == 1,
                "Estimate removal corrupted total or completion counters")
}

test("Estimate generations and live identities reject stale settings and removed imports") {
    let store = OutputEstimateStore()
    let original = UUID(), reimported = UUID(), other = UUID()
    let value = OutputEstimateValue.ready(OutputSizeEstimate(width: 10, height: 5, outputBytes: 777, skipped: false, formatExtension: "jpg"))
    store.append([original, other])
    let generation = store.generation
    store.remove([original]); store.append([reimported])
    try require(!store.record(value, for: original, generation: generation) && store.record(value, for: reimported, generation: generation),
                "Removed completion was accepted after importing the same path with a new identity")
    store.reset()
    try require(store.count == 2 && store.pendingCount == 2 && store.completedCount == 0 && store.totalBytes == 0,
                "Settings invalidation discarded membership or retained old estimates")
    try require(!store.record(value, for: reimported, generation: generation) &&
                !store.record(value, for: UUID(), generation: store.generation), "Estimate accepted a stale generation or unknown input")
    try require(store.record(.unavailable("Trial failed"), for: other, generation: store.generation) && store.failureCount == 1,
                "Current failure completion was not stored")
    store.clear()
    let final = UUID(); store.append([final])
    try require(store.count == 1 && store.pendingCount == 1 && store.failureCount == 0 && store.skippedCount == 0 && store.totalBytes == 0,
                "Clear/reimport retained values from the previous batch")
    try require(!store.record(value, for: other, generation: store.generation) && store.record(value, for: final, generation: store.generation),
                "Clear/reimport accepted stale membership or rejected a current result")
    if case .ready(let saved)? = store.value(for: final) {
        try require(saved.outputBytes == 777 && saved.formatExtension == "jpg" && store.totalBytes == 777, "Current estimate value was corrupted")
    } else { throw TestFailure("Current estimate value was unavailable") }
}

test("Produce clean product-style watermark previews") {
    let width = 1600
    let height = 1000
    let context = CGContext(data: nil, width: width + 1, height: height + 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width + 1, height: height + 1))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 38, color: CGColor(gray: 0, alpha: 0.14))
    context.setFillColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1)
    context.addPath(CGPath(roundedRect: CGRect(x: 210, y: 175, width: 585, height: 665), cornerWidth: 42, cornerHeight: 42, transform: nil))
    context.fillPath()
    context.restoreGState()
    context.setFillColor(red: 0.1, green: 0.48, blue: 0.89, alpha: 1)
    context.fillEllipse(in: CGRect(x: 760, y: 280, width: 480, height: 480))
    context.setFillColor(red: 0.98, green: 0.69, blue: 0.19, alpha: 1)
    context.addPath(CGPath(roundedRect: CGRect(x: 540, y: 285, width: 245, height: 400), cornerWidth: 38, cornerHeight: 38, transform: nil))
    context.fillPath()
    context.setFillColor(red: 0.13, green: 0.16, blue: 0.2, alpha: 1)
    context.fillEllipse(in: CGRect(x: 397, y: 370, width: 205, height: 205))
    let source = try fixture("watermark-product.png", image: context.makeImage()!)
    let preview = root.deletingLastPathComponent().appendingPathComponent("watermark-preview", isDirectory: true)
    try fileManager.createDirectory(at: preview, withIntermediateDirectories: true)
    let examples = [("short", "SAMPLE"), ("long", "North Coast Photography — Private Preview"),
                    ("unicode", "样片 • Café • Αλέξανδρος • مرحبا")]
    for (name, text) in examples {
        let url = try outputURL(watermarked(source, text: text))
        try assertDimensions(url, width, height)
        try Data(contentsOf: url).write(to: preview.appendingPathComponent("watermark-\(name).png"), options: .atomic)
    }
    print("Watermark previews: \(preview.path)")
}

print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    print("Fixtures and outputs: \(work.path)")
    exit(1)
}
try? fileManager.removeItem(at: work)
