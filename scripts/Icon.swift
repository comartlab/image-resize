// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// The icon is drawn natively and rasterized separately at every required size.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name, size) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext; cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let outline = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.59, blue: 0.70, alpha: 1), ending: NSColor(calibratedRed: 0.15, green: 0.29, blue: 0.75, alpha: 1))!.draw(in: outline, angle: 65)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    let outer = NSBezierPath(roundedRect: NSRect(x: 240, y: 266, width: 510, height: 416), xRadius: 42, yRadius: 42)
    outer.lineWidth = 18; outer.stroke()
    NSColor.white.setStroke()
    let inner = NSBezierPath(roundedRect: NSRect(x: 378, y: 366, width: 246, height: 214), xRadius: 22, yRadius: 22)
    inner.lineWidth = 20; inner.stroke()
    let mountain = NSBezierPath(); mountain.move(to: NSPoint(x: 398, y: 390)); mountain.line(to: NSPoint(x: 467, y: 466)); mountain.line(to: NSPoint(x: 520, y: 417)); mountain.line(to: NSPoint(x: 551, y: 450)); mountain.line(to: NSPoint(x: 600, y: 393))
    mountain.lineWidth = 17; mountain.lineJoinStyle = .round; mountain.stroke()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 540, y: 500, width: 28, height: 28)).fill()
    func arrow(_ from: NSPoint, _ to: NSPoint, _ a: NSPoint, _ b: NSPoint) {
        let path = NSBezierPath(); path.lineWidth = 26; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: from); path.line(to: to); path.move(to: a); path.line(to: to); path.line(to: b); path.stroke()
    }
    arrow(NSPoint(x: 246,y: 744), NSPoint(x: 358,y: 632), NSPoint(x: 286,y: 632), NSPoint(x: 358,y: 704))
    arrow(NSPoint(x: 758,y: 204), NSPoint(x: 654,y: 308), NSPoint(x: 654,y: 236), NSPoint(x: 726,y: 308))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}

// ICNS accepts PNG payloads for these modern icon slots. Writing the container
// directly also works in build environments where iconutil's helper is absent.
if CommandLine.arguments.count > 2 {
    func bigEndian(_ value: UInt32) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
    var chunks = Data()
    for (slot, filename) in [("icp4","icon_16x16.png"),("icp5","icon_32x32.png"),("icp6","icon_32x32@2x.png"),("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png"),("ic11","icon_16x16@2x.png"),("ic12","icon_32x32@2x.png"),("ic13","icon_128x128@2x.png"),("ic14","icon_256x256@2x.png")] {
        let png = try Data(contentsOf: destination.appendingPathComponent(filename))
        chunks.append(slot.data(using: .ascii)!); chunks.append(bigEndian(UInt32(png.count + 8))); chunks.append(png)
    }
    var icns = "icns".data(using: .ascii)!
    icns.append(bigEndian(UInt32(chunks.count + 8))); icns.append(chunks)
    try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
