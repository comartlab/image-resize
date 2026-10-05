// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

/// Optional validation of Photoshop-resaved copies of LayerFixtures. The
/// application-produced documents stay under build and are not test dependencies.
@main
struct LayerValidation {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() {
        do { try run() }
        catch { print("FAIL Photoshop supplemental validation: \(error)"); exit(1) }
    }

    static func run() throws {
        guard CommandLine.arguments.count >= 3 else {
            throw Failure("Usage: layer-validation output-folder photoshop-resaved.psd [more PSD files]")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for path in CommandLine.arguments.dropFirst(2) {
            let input = URL(fileURLWithPath: path)
            let probes: [(Double, Double, [UInt8])]
            if input.lastPathComponent.contains("gray") {
                probes = [(0.2, 0.2, [129, 129, 129, 255]), (0.8, 0.2, [0, 0, 0, 0]),
                          (0.2, 0.8, [175, 175, 175, 255]), (0.8, 0.8, [110, 110, 110, 128])]
            } else if input.lastPathComponent.contains("cmyk") {
                probes = [(0.2, 0.2, [237, 52, 55, 255]), (0.8, 0.2, [0, 0, 0, 0]),
                          (0.2, 0.8, [186, 138, 65, 255]), (0.8, 0.8, [56, 95, 40, 128])]
            } else {
                probes = [(0.2, 0.2, [255, 0, 0, 255]), (0.8, 0.2, [0, 0, 0, 0]),
                          (0.2, 0.8, [127, 128, 0, 255]), (0.8, 0.8, [0, 128, 0, 128])]
            }
            let before = SHA256.hash(data: try Data(contentsOf: input))
            let item = try ResizeEngine.inspect(input)
            guard item.width == 80 && item.height == 48,
                  let inputSource = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let inputImage = CGImageSourceCreateImageAtIndex(inputSource, 0, nil) else {
                throw Failure("Expected the 80×48 Photoshop-resaved layered fixture")
            }
            for format in [OutputFormat.png, .tiff, .jpeg] {
                var settings = ResizeSettings()
                settings.width = 40
                settings.format = format
                settings.quality = 1
                let result = try ResizeEngine.resize(item, to: output, settings: settings)
                guard let url = result.output,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let context = CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw Failure("Cannot decode \(format) supplemental output")
                }
                guard image.width == 40 && image.height == 24 else { throw Failure("Wrong output dimensions") }
                if inputImage.bitsPerComponent == 16 && format != .jpeg && image.bitsPerComponent != 16 {
                    throw Failure("16-bit Photoshop PSD export lost channel depth")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
                for (x, y, expected) in probes {
                    let pixel = (Int(Double(image.height) * y) * image.width + Int(Double(image.width) * x)) * 4
                    let actual = (0..<4).map { bytes[pixel + $0] }
                    let target: [UInt8]
                    if format == .jpeg {
                        let alpha = expected[3]
                        target = expected.prefix(3).map { UInt8(clamping: Int($0) + 255 - Int(alpha)) } + [255]
                    } else { target = expected }
                    guard zip(actual, target).allSatisfy({ abs(Int($0.0) - Int($0.1)) <= (format == .jpeg ? 8 : 3) }) else {
                        throw Failure("\(input.lastPathComponent) \(format) composite at \(x),\(y): expected \(target), got \(actual)")
                    }
                }
                let adobe = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
                guard (adobe?["{8BIM}"] as? [String: Any])?["LayerNames"] == nil else {
                    throw Failure("Supplemental export retained Photoshop layer names")
                }
                print("PASS \(input.lastPathComponent) → \(format) 40×24 depth\(image.bitsPerComponent) correct composite")
            }
            guard SHA256.hash(data: try Data(contentsOf: input)) == before else {
                throw Failure("Photoshop-resaved source changed during export")
            }
        }
    }
}
