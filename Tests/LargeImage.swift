// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

@main
struct LargeImageRegression {
    static func main() {
        do { try run() }
        catch {
            fputs("Large-image regression failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else {
            throw LargeImageFailure("Supply an input image path and a workspace output folder")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let overallStart = DispatchTime.now().uptimeNanoseconds
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let runFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let item = try ResizeEngine.inspect(input)
        let originalHash = try sha256(input)
        let inputProfile = try profile(input)
        print("Input: \(item.width)×\(item.height), \(item.fileBytes) bytes, \(item.typeIdentifier)")
        print("Source SHA-256 before: \(originalHash)")
        print("Color profile: \(inputProfile.name ?? "none")")
        let variants: [(String, Int, Bool)] = [
            ("plain-1600", 1600, false),
            ("watermarked-1600", 1600, true),
            ("watermarked-original-size-skip", max(item.width, item.height), true)
        ]
        var reductions = 0
        var skipped = 0
        for (name, bound, watermark) in variants {
            let folder = runFolder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var settings = ResizeSettings()
            settings.width = bound
            settings.format = .original
            settings.watermarkEnabled = watermark
            settings.watermarkText = "SAMPLE"
            let expected = try ResizeEngine.targetSize(width: item.width, height: item.height, settings: settings)
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try autoreleasepool { try ResizeEngine.resize(item, to: folder, settings: settings) }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            if expected.width == item.width && expected.height == item.height {
                guard result.skipped, result.output == nil, result.outputBytes == 0,
                      try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
                    throw LargeImageFailure("\(name) wrote an output instead of skipping an already-fitting image")
                }
                print(String(format: "%@: %.3f s; correctly skipped without output", name, elapsed))
                skipped += 1
                continue
            }
            guard let output = result.output else { throw LargeImageFailure("\(name) returned no output") }
            let written = try ResizeEngine.inspect(output)
            guard written.width == expected.width, written.height == expected.height,
                  result.width == expected.width, result.height == expected.height,
                  written.fileBytes > 0, !result.skipped else {
                throw LargeImageFailure("\(name) returned incorrect dimensions, empty data or unexpected passthrough")
            }
            let outputProfile = try profile(output)
            guard inputProfile.icc == outputProfile.icc else {
                throw LargeImageFailure("\(name) changed the source ICC profile")
            }
            try verifyPixels(output)
            print(String(format: "%@: %.3f s, %d×%d, %lld bytes; ICC retained; decoded thumbnail valid", name,
                         elapsed, written.width, written.height, written.fileBytes))
            print("Output: \(output.path)")
            reductions += 1
            fflush(stdout)
        }
        let finalHash = try sha256(input)
        guard finalHash == originalHash else { throw LargeImageFailure("Original source bytes changed") }
        print("Source SHA-256 after: \(finalHash) (unchanged)")
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            print(String(format: "Peak resident memory: %lld bytes (%.1f MiB), process-wide getrusage", usage.ru_maxrss,
                         Double(usage.ru_maxrss) / 1_048_576))
        } else {
            print("Peak resident memory measurement unavailable: errno \(errno)")
        }
        let overallElapsed = Double(DispatchTime.now().uptimeNanoseconds - overallStart) / 1_000_000_000
        print(String(format: "Whole regression elapsed: %.3f s, including validation", overallElapsed))
        print("PASS \(reductions) reductions and \(skipped) already-fitting skips; outputs: \(runFolder.path)")
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func profile(_ url: URL) throws -> (name: String?, icc: Data?) {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw LargeImageFailure("Cannot inspect image color profile")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            return (properties?[kCGImagePropertyProfileName as String] as? String,
                    image.colorSpace?.copyICCData() as Data?)
        }
    }

    static func verifyPixels(_ url: URL) throws {
        try autoreleasepool {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 64]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  thumbnail.width > 0, thumbnail.height > 0,
                  let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LargeImageFailure("Output image pixels cannot be decoded")
            }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            guard context.makeImage() != nil else { throw LargeImageFailure("Output pixel readback failed") }
        }
    }
}

struct LargeImageFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
