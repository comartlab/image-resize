// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

/// Small, genuine layered documents written from Adobe's published structures.
/// PSD: https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
/// TIFF: Adobe Photoshop TIFF Technical Notes (2002), Image Source Data, p.11.
/// Both layered formats use big-endian layer fields; TIFF itself is MM so its
/// private layer payload has the same byte order as the surrounding document.
enum LayerFixtures {
    static let width = 80
    static let height = 48
    static let layerMarker = Data("Adobe Photoshop Document Data Block\0".utf8)

    struct Documents {
        let psd: URL
        let psd16: URL
        let opaquePSD: URL
        let incompatiblePSD: URL
        let missingCompositePSD: URL
        let tiff: URL
        let tiff16: URL
    }

    static func create(in folder: URL) throws -> Documents {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = Documents(psd: folder.appendingPathComponent("layered-compatible.psd"),
                              psd16: folder.appendingPathComponent("layered-compatible-16.psd"),
                              opaquePSD: folder.appendingPathComponent("layered-opaque.psd"),
                              incompatiblePSD: folder.appendingPathComponent("layered-no-compatibility.psd"),
                              missingCompositePSD: folder.appendingPathComponent("layered-missing-composite.psd"),
                              tiff: folder.appendingPathComponent("layered-rgba.tiff"),
                              tiff16: folder.appendingPathComponent("layered-rgba-16.tiff"))
        try psdData(hasMerged: true).write(to: paths.psd)
        try psdData(hasMerged: true, depth: 16).write(to: paths.psd16)
        try psdData(hasMerged: true, opaque: true).write(to: paths.opaquePSD)
        try psdData(hasMerged: false).write(to: paths.incompatiblePSD)
        // Claiming compatibility cannot make omitted composite bytes usable.
        try psdData(hasMerged: true, omitComposite: true).write(to: paths.missingCompositePSD)
        try tiffData(depth: 8).write(to: paths.tiff)
        try tiffData(depth: 16).write(to: paths.tiff16)
        return paths
    }

    struct ModeDocument {
        let url: URL
        let reference: CGImage
        let depth: Int
    }

    /// Independent color-mode controls: the reference is rendered directly
    /// from ordinary opaque CoreGraphics gray/CMYK pixels, then alpha is applied.
    /// It does not decode a PSD or use the engine's matte normalization.
    static func createColorModes(in folder: URL) throws -> [ModeDocument] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var documents = [ModeDocument]()
        for (mode, depth) in [(1, 8), (1, 16), (4, 8)] {
            let space = CGColorSpace(name: mode == 1 ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.genericCMYK)!
            let base: [UInt16] = mode == 1 ? [49344] : [32896, 16448, 0, 8224]
            let overlay: [UInt16] = mode == 1 ? [16448] : [0, 49344, 65535, 16448]
            let hidden = [UInt16](repeating: mode == 1 ? 65535 : 0, count: base.count)
            func pixel(_ x: Int, _ y: Int) -> ([UInt16], UInt16) {
                if y < height / 2 { return (base, x < width / 2 ? 65535 : 0) }
                if x >= width / 2 { return (overlay, 32896) }
                let blended: [UInt16] = zip(base, overlay).map { values in
                    let lower = Double(values.0) * 127.0
                    let upper = Double(values.1) * 128.0
                    return UInt16(((lower + upper) / 255.0).rounded())
                }
                return (blended, 65535)
            }
            var opaque = BinaryWriter()
            for y in 0..<height { for x in 0..<width {
                for value in pixel(x, y).0 {
                    if depth == 8 { opaque.u8(UInt8(value / 257)) } else { opaque.u16(value) }
                }
            } }
            let provider = CGDataProvider(data: opaque.data as CFData)!
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                         | (depth == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0))
            let image = CGImage(width: width, height: height, bitsPerComponent: depth,
                                bitsPerPixel: depth * base.count, bytesPerRow: width * base.count * depth / 8,
                                space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = Int(pixel(x, y).1 / 257)
                for channel in 0..<3 { bytes[offset + channel] = UInt8((Int(bytes[offset + channel]) * alpha + 127) / 255) }
                bytes[offset + 3] = UInt8(alpha)
            } }
            let reference = context.makeImage()!
            var records = BinaryWriter(); records.i16(-3)
            var channels = BinaryWriter()
            for (index, color) in [base, overlay, hidden].enumerated() {
                let top = index == 1 ? height / 2 : 0
                records.i32(top); records.i32(0); records.i32(height); records.i32(width)
                records.u16(base.count + 1)
                for channel in [-1] + Array(0..<base.count) {
                    var payload = BinaryWriter(); payload.u16(0)
                    for _ in top..<height { for x in 0..<width {
                        let value = channel == -1 ? (index == 0 && x >= width / 2 ? UInt16(0) : 65535)
                            : mode == 4 ? 65535 - color[channel] : color[channel]
                        if depth == 8 { payload.u8(UInt8(value / 257)) } else { payload.u16(value) }
                    } }
                    records.i16(channel); records.u32(payload.data.count); channels.bytes(payload.data)
                }
                records.ascii("8BIM"); records.ascii("norm")
                records.u8(index == 1 ? 128 : 255); records.u8(0); records.u8(index == 2 ? 2 : 0); records.u8(0)
                var extra = BinaryWriter(); extra.u32(0); extra.u32(0)
                let name = "Mode layer \(index + 1)"
                extra.u8(UInt8(name.utf8.count)); extra.ascii(name)
                while (extra.data.count - 8) % 4 != 0 { extra.u8(0) }
                records.u32(extra.data.count); records.bytes(extra.data)
            }
            records.bytes(channels.data)
            if !records.data.count.isMultiple(of: 2) { records.u8(0) }
            var mask = BinaryWriter()
            if depth == 8 { mask.u32(records.data.count); mask.bytes(records.data); mask.u32(0) }
            else {
                mask.u32(0); mask.u32(0); mask.ascii("8BIM"); mask.ascii("Lr16")
                mask.u32(records.data.count); mask.bytes(records.data)
                while !mask.data.count.isMultiple(of: 4) { mask.u8(0) }
            }
            var resources = BinaryWriter()
            resources.bytes(resource(id: 1039, data: space.copyICCData()! as Data))
            var version = BinaryWriter(); version.u32(1); version.u8(1)
            version.unicode("Native regression fixture"); version.unicode("Native regression fixture"); version.u32(1)
            resources.bytes(resource(id: 1057, data: version.data))
            var file = BinaryWriter()
            file.ascii("8BPS"); file.u16(1); file.bytes(Data(repeating: 0, count: 6))
            file.u16(base.count + 1); file.u32(height); file.u32(width); file.u16(depth); file.u16(mode)
            file.u32(0); file.u32(resources.data.count); file.bytes(resources.data)
            file.u32(mask.data.count); file.bytes(mask.data); file.u16(0)
            for channel in 0...base.count { for y in 0..<height { for x in 0..<width {
                let (color, alpha) = pixel(x, y)
                let fraction = Double(alpha) / 65535
                let value = channel == base.count ? Double(alpha)
                    : mode == 4 ? 65535 - Double(color[channel]) * fraction
                    : Double(color[channel]) * fraction + 65535 * (1 - fraction)
                if depth == 8 { file.u8(UInt8(clamping: Int((value / 257).rounded()))) }
                else { file.u16(UInt16(clamping: Int(value.rounded()))) }
            } } }
            let url = folder.appendingPathComponent("layered-\(mode == 1 ? "gray" : "cmyk")-\(depth).psd")
            try file.data.write(to: url)
            documents.append(ModeDocument(url: url, reference: reference, depth: depth))
        }
        return documents
    }

    /// A hidden opaque magenta layer, a visible half-opacity green bottom
    /// layer, and a red base layer opaque only on the left. The visible merged
    /// quadrants are red, transparent, olive, and half-transparent green.
    static func composite(x: Int, y: Int, opaque: Bool = false) -> [UInt16] {
        if y < height / 2 { return opaque || x < width / 2 ? [65535, 0, 0, 65535] : [0, 0, 0, 0] }
        return opaque || x < width / 2 ? [32639, 32896, 0, 65535] : [0, 65535, 0, 32896]
    }

    private struct Layer {
        let name: String
        let top: Int
        let opacity: UInt8
        let hidden: Bool
        let color: [UInt16]
        let transparentRight: Bool
    }

    private static let layers = [
        // Photoshop layer indexes count upward from the bottom/background.
        Layer(name: "Red left base", top: 0, opacity: 255, hidden: false, color: [65535, 0, 0], transparentRight: true),
        Layer(name: "Green at 50 percent", top: height / 2, opacity: 128, hidden: false, color: [0, 65535, 0], transparentRight: false),
        Layer(name: "Hidden magenta", top: 0, opacity: 255, hidden: true, color: [65535, 0, 65535], transparentRight: false)
    ]

    private static func layerInfo(depth: Int, opaque: Bool = false) -> Data {
        var records = BinaryWriter()
        records.i16(opaque ? layers.count : -layers.count)
        var channels = BinaryWriter()
        for layer in layers {
            records.i32(layer.top); records.i32(0); records.i32(height); records.i32(width)
            records.u16(4)
            for channel in [-1, 0, 1, 2] {
                var payload = BinaryWriter()
                payload.u16(0) // Uncompressed channel data, including this word.
                for _ in layer.top..<height {
                    for x in 0..<width {
                        let value: UInt16 = channel == -1
                            ? (layer.transparentRight && !opaque && x >= width / 2 ? 0 : 65535)
                            : layer.color[channel]
                        if depth == 8 { payload.u8(UInt8(value / 257)) } else { payload.u16(value) }
                    }
                }
                records.i16(channel); records.u32(payload.data.count)
                channels.bytes(payload.data)
            }
            records.ascii("8BIM"); records.ascii("norm")
            records.u8(layer.opacity); records.u8(0)
            records.u8(layer.hidden ? 2 : 0); records.u8(0)
            var extra = BinaryWriter()
            extra.u32(0) // Layer mask.
            extra.u32(0) // Blending ranges.
            extra.u8(UInt8(layer.name.utf8.count)); extra.ascii(layer.name)
            while (extra.data.count - 8) % 4 != 0 { extra.u8(0) }
            records.u32(extra.data.count); records.bytes(extra.data)
        }
        records.bytes(channels.data)
        if !records.data.count.isMultiple(of: 2) { records.u8(0) }
        return records.data
    }

    private static func resource(id: UInt16, data: Data) -> Data {
        var result = BinaryWriter()
        result.ascii("8BIM"); result.u16(id); result.u16(0) // Empty Pascal name, even padded.
        result.u32(data.count); result.bytes(data)
        if !data.count.isMultiple(of: 2) { result.u8(0) }
        return result.data
    }

    private static func psdData(hasMerged: Bool, omitComposite: Bool = false, depth: Int = 8, opaque: Bool = false) -> Data {
        var writer = BinaryWriter()
        writer.ascii("8BPS"); writer.u16(1); writer.bytes(Data(repeating: 0, count: 6))
        writer.u16(opaque ? 3 : 4); writer.u32(height); writer.u32(width); writer.u16(depth); writer.u16(3)
        writer.u32(0) // Color mode data.
        var resources = BinaryWriter()
        let profile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        resources.bytes(resource(id: 1039, data: profile))
        var version = BinaryWriter()
        version.u32(1); version.u8(hasMerged ? 1 : 0)
        version.unicode("Native regression fixture"); version.unicode("Native regression fixture")
        version.u32(1)
        resources.bytes(resource(id: 1057, data: version.data))
        writer.u32(resources.data.count); writer.bytes(resources.data)
        var maskSection = BinaryWriter()
        let info = layerInfo(depth: depth, opaque: opaque)
        if depth == 8 {
            maskSection.u32(info.count); maskSection.bytes(info); maskSection.u32(0)
        } else {
            // Photoshop stores high-depth layer records in the Lr16 additional
            // layer-information block rather than the primary 8-bit section.
            maskSection.u32(0); maskSection.u32(0)
            maskSection.ascii("8BIM"); maskSection.ascii("Lr16")
            maskSection.u32(info.count); maskSection.bytes(info)
            while !maskSection.data.count.isMultiple(of: 4) { maskSection.u8(0) }
        }
        writer.u32(maskSection.data.count); writer.bytes(maskSection.data)
        if omitComposite { return writer.data }
        writer.u16(0)
        for channel in 0..<(opaque ? 3 : 4) {
            for y in 0..<height {
                for x in 0..<width {
                    if !hasMerged {
                        if depth == 8 { writer.u8(255) } else { writer.u16(65535) }
                    } else {
                        let pixel = composite(x: x, y: y, opaque: opaque)
                        let alpha = Double(pixel[3]) / 65535
                        let maximum = depth == 8 ? 255.0 : 65535.0
                        let value = channel == 3 ? alpha * maximum
                            : (Double(pixel[channel]) / 65535 * alpha + 1 - alpha) * maximum
                        if depth == 8 { writer.u8(UInt8(clamping: Int(value.rounded()))) }
                        else { writer.u16(UInt16(clamping: Int(value.rounded()))) }
                    }
                }
            }
        }
        return writer.data
    }

    private static func tiffData(depth: Int) -> Data {
        var layerData = BinaryWriter()
        layerData.bytes(layerMarker); layerData.ascii("8BIM")
        layerData.ascii(depth == 16 ? "Lr16" : "Layr")
        let info = layerInfo(depth: depth)
        layerData.u32(info.count); layerData.bytes(info)
        while !layerData.data.count.isMultiple(of: 4) { layerData.u8(0) }
        var pixels = BinaryWriter()
        for y in 0..<height {
            for x in 0..<width {
                for value in composite(x: x, y: y) {
                    if depth == 8 { pixels.u8(UInt8(value / 257)) } else { pixels.u16(value) }
                }
            }
        }
        var fields: [(UInt16, UInt16, Int, Data)] = []
        func short(_ tag: UInt16, _ value: Int) {
            var data = BinaryWriter(); data.u16(value)
            fields.append((tag, 3, 1, data.data))
        }
        func long(_ tag: UInt16, _ value: Int) {
            var data = BinaryWriter(); data.u32(value)
            fields.append((tag, 4, 1, data.data))
        }
        long(256, width); long(257, height)
        var depths = BinaryWriter(); for _ in 0..<4 { depths.u16(depth) }
        fields.append((258, 3, 4, depths.data))
        short(259, 1); short(262, 2)
        long(273, 0) // Filled once directory and auxiliary field data are sized.
        short(277, 4); long(278, height); long(279, pixels.data.count)
        short(284, 1); short(338, 2) // Unassociated RGBA transparency.
        let profile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        fields.append((34675, 7, profile.count, profile))
        fields.append((37724, 7, layerData.data.count, layerData.data))
        fields.sort { $0.0 < $1.0 }
        let extraStart = 8 + 2 + fields.count * 12 + 4
        var extras = BinaryWriter()
        var directory = BinaryWriter()
        directory.u16(fields.count)
        let stripOffset = extraStart + fields.filter { $0.3.count > 4 }.reduce(0) { $0 + $1.3.count + ($1.3.count % 2) }
        for (tag, type, count, data) in fields {
            directory.u16(tag); directory.u16(type); directory.u32(count)
            if tag == 273 {
                directory.u32(stripOffset)
            } else if data.count <= 4 {
                directory.bytes(data); directory.bytes(Data(repeating: 0, count: 4 - data.count))
            } else {
                directory.u32(extraStart + extras.data.count); extras.bytes(data)
                if !extras.data.count.isMultiple(of: 2) { extras.u8(0) }
            }
        }
        directory.u32(0) // Exactly one IFD; real layers live in private tag 37724.
        var file = BinaryWriter()
        file.ascii("MM"); file.u16(42); file.u32(8)
        file.bytes(directory.data); file.bytes(extras.data); file.bytes(pixels.data)
        return file.data
    }

    static func tiffTags(_ data: Data) -> Set<UInt16> {
        guard data.count >= 8 else { return [] }
        let little = data.prefix(2) == Data("II".utf8)
        guard little || data.prefix(2) == Data("MM".utf8) else { return [] }
        func number(_ offset: Int, _ length: Int) -> Int? {
            guard offset >= 0 && offset + length <= data.count else { return nil }
            var value = 0
            for index in 0..<length {
                value |= Int(data[offset + index]) << ((little ? index : length - index - 1) * 8)
            }
            return value
        }
        guard let offset = number(4, 4), let count = number(offset, 2) else { return [] }
        var result = Set<UInt16>()
        for index in 0..<count {
            if let tag = number(offset + 2 + index * 12, 2) { result.insert(UInt16(tag)) }
        }
        return result
    }

    static func psdLayerCount(_ data: Data) -> Int? {
        guard data.count >= 34 && data.prefix(4) == Data("8BPS".utf8) else { return nil }
        func number(_ offset: Int, _ length: Int) -> Int? {
            guard offset >= 0 && offset + length <= data.count else { return nil }
            var value = 0
            for index in 0..<length { value = (value << 8) | Int(data[offset + index]) }
            return value
        }
        guard let colorLength = number(26, 4) else { return nil }
        let resourceOffset = 30 + colorLength
        guard let resourceLength = number(resourceOffset, 4) else { return nil }
        let maskOffset = resourceOffset + 4 + resourceLength
        guard let maskLength = number(maskOffset, 4) else { return nil }
        if maskLength == 0 { return 0 }
        guard let layerLength = number(maskOffset + 4, 4) else { return nil }
        if layerLength > 0 {
            guard let count = number(maskOffset + 8, 2) else { return nil }
            return Int(Int16(bitPattern: UInt16(count)))
        }
        let globalMaskOffset = maskOffset + 8
        guard let globalLength = number(globalMaskOffset, 4) else { return nil }
        var cursor = globalMaskOffset + 4 + globalLength
        let end = maskOffset + 4 + maskLength
        while cursor + 12 <= min(end, data.count) {
            guard data[cursor..<(cursor + 4)] == Data("8BIM".utf8),
                  let length = number(cursor + 8, 4) else { return nil }
            let key = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
            if key == "Lr16" || key == "Lr32" {
                guard length >= 2, let count = number(cursor + 12, 2) else { return nil }
                return Int(Int16(bitPattern: UInt16(count)))
            }
            cursor += 12 + length + (4 - length % 4) % 4
        }
        return 0
    }
}

private struct BinaryWriter {
    var data = Data()
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: Int) { u16(UInt16(value)) }
    mutating func u16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 255)) }
    mutating func i16(_ value: Int) { u16(UInt16(bitPattern: Int16(value))) }
    mutating func u32(_ value: Int) {
        let value = UInt32(value)
        data.append(UInt8(value >> 24)); data.append(UInt8((value >> 16) & 255))
        data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255))
    }
    mutating func i32(_ value: Int) { u32(value) }
    mutating func unicode(_ value: String) {
        u32(value.utf16.count + 1)
        for unit in value.utf16 { u16(unit) }
        u16(0)
    }
}
