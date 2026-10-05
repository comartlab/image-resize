// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO

@main
struct ResizeBenchmark {
    static func main() {
        do { try run() }
        catch {
            fputs("Benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/benchmark-work", isDirectory: true)
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let input = work.appendingPathComponent("synthetic-24mp.jpg")
        try createFixture(at: input)
        let item = try ResizeEngine.inspect(input)
        var settings = ResizeSettings()
        settings.mode = .longestEdge
        settings.width = 1600
        settings.format = .original
        settings.quality = 0.9
        print("Input: \(item.width)×\(item.height) synthetic RGB JPEG, \(item.fileBytes) bytes")
        print("Output: longest edge 1600, original JPEG format, quality 90%")
        print("Timing includes decode, native resampling, JPEG encoding and file writing; fixture generation is excluded.")
        var durations = [Double]()
        for index in 1...3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try autoreleasepool {
                try ResizeEngine.resize(item, to: work, settings: settings)
            }
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            guard let url = result.output,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == 1600, image.height == 1067,
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  !result.skipped else {
                throw BenchmarkFailure("Output failed dimensions or decode validation")
            }
            durations.append(duration)
            print(String(format: "Run %d: %.3f s; output %d×%d, %lld bytes", index, duration,
                         image.width, image.height, result.outputBytes))
        }
        let mean = durations.reduce(0, +) / Double(durations.count)
        print(String(format: "Mean: %.3f s; range %.3f–%.3f s", mean, durations.min()!, durations.max()!))
        print("Synthetic input and cached filesystem; this is not a Photoshop comparison or a physical Intel benchmark.")
    }

    static func createFixture(at url: URL) throws {
        let width = 6000
        let height = 4000
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Smooth color gradients, broad color patches and fine deterministic
        // texture exercise decoding/filtering without external photo assets.
        for y in 0..<height {
            let vertical = y * 255 / (height - 1)
            for x in 0..<width {
                let horizontal = x * 255 / (width - 1)
                let hash = UInt32(truncatingIfNeeded: x &* 73856093) ^ UInt32(truncatingIfNeeded: y &* 19349663)
                let texture = Int((hash ^ (hash >> 13)) & 31) - 15
                let patch = ((x / 300 + y / 250) % 2) * 35
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(clamping: horizontal + texture)
                bytes[offset + 1] = UInt8(clamping: vertical - texture)
                bytes[offset + 2] = UInt8(clamping: (horizontal + vertical) / 2 + patch + texture)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw BenchmarkFailure("Could not create synthetic JPEG fixture")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BenchmarkFailure("Could not encode fixture") }
    }
}

struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
