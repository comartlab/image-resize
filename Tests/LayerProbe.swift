// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ImageIO
import CoreGraphics

@main
struct LayerProbe {
    static func main() throws {
        let urls: [URL]
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--inspect" {
            urls = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
        } else {
            let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/layered-fixtures", isDirectory: true)
            let fixtures = try LayerFixtures.create(in: folder)
            urls = [fixtures.psd, fixtures.psd16, fixtures.opaquePSD, fixtures.incompatiblePSD, fixtures.missingCompositePSD, fixtures.tiff, fixtures.tiff16]
        }
        for url in urls {
            let encoded = try Data(contentsOf: url)
            print("\(url.lastPathComponent): PSD layer count=\(LayerFixtures.psdLayerCount(encoded).map(String.init) ?? "n/a"), TIFF ImageSourceData=\(LayerFixtures.tiffTags(encoded).contains(37724))")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                print("\(url.lastPathComponent): no ImageIO source"); continue
            }
            print("\(url.lastPathComponent): type=\(CGImageSourceGetType(source) as String? ?? "nil"), count=\(CGImageSourceGetCount(source))")
            print(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as Any)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                print("No decoded composite pixels"); continue
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            let probes = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
            let colors = probes.map { probe -> [UInt8] in
                let offset = (Int(Double(image.height) * probe.1) * image.width + Int(Double(image.width) * probe.0)) * 4
                return (0..<4).map { bytes[offset + $0] }
            }
            print("Pixels: \(image.width)×\(image.height), depth=\(image.bitsPerComponent), alpha=\(image.alphaInfo.rawValue), probes=\(colors)")
        }
    }
}
