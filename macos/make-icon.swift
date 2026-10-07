// Draws the ClipStack icon and writes it for both apps:
//   macos/AppIcon.icns        (via iconutil)
//   windows/app/ClipStack.ico (PNG-compressed entries, Vista and later)
//
//   swift macos/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

/// A stack of three cards on a blue tile. `inset` leaves the margin macOS icons use.
func draw(size: Int, inset: CGFloat) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let tile = CGRect(x: s * inset, y: s * inset, width: s * (1 - 2 * inset), height: s * (1 - 2 * inset))
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(red: 0.36, green: 0.58, blue: 1.0, alpha: 1).cgColor,
                                       NSColor(red: 0.27, green: 0.30, blue: 0.86, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Cards: back to front, each a little lower and further left.
    let w = tile.width * 0.50, h = tile.width * 0.58
    let step = tile.width * 0.085
    let origin = CGPoint(x: tile.midX - w / 2 + step, y: tile.midY - h / 2 + step)
    for (i, alpha) in [0.38, 0.65, 1.0].enumerated() {
        let r = CGRect(x: origin.x - CGFloat(i) * step, y: origin.y - CGFloat(i) * step, width: w, height: h)
        let card = CGPath(roundedRect: r, cornerWidth: w * 0.12, cornerHeight: w * 0.12, transform: nil)
        ctx.saveGState()
        if i == 2 { ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor(white: 0, alpha: 0.3).cgColor) }
        ctx.addPath(card)
        ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        if i == 2 {
            // Lines of "text" on the front card.
            let line = NSColor(red: 0.30, green: 0.36, blue: 0.86, alpha: 0.85)
            ctx.setFillColor(line.cgColor)
            let lw = [0.62, 0.74, 0.48]
            for (j, frac) in lw.enumerated() {
                let lh = h * 0.075
                let lr = CGRect(x: r.minX + w * 0.17, y: r.maxY - h * 0.25 - CGFloat(j) * h * 0.2, width: w * frac, height: lh)
                ctx.addPath(CGPath(roundedRect: lr, cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil))
                ctx.fillPath()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS: an iconset, then iconutil.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("ClipStack.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(size: base, inset: 0.1).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2, inset: 0.1).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("macos/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

// Windows: an .ico holding PNGs, edge to edge as Windows icons are.
let sizes = [256, 48, 32, 16]
let images = sizes.map { draw(size: $0, inset: 0.02) }
var ico = Data([0, 0, 1, 0, UInt8(sizes.count), 0])
var offset = 6 + 16 * sizes.count
for (size, png) in zip(sizes, images) {
    var entry = Data([UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0, 1, 0, 32, 0])
    withUnsafeBytes(of: UInt32(png.count).littleEndian) { entry.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(offset).littleEndian) { entry.append(contentsOf: $0) }
    ico.append(entry)
    offset += png.count
}
images.forEach { ico.append($0) }
let icoURL = root.appendingPathComponent("windows/app/ClipStack.ico")
try! FileManager.default.createDirectory(at: icoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! ico.write(to: icoURL)

// A large PNG for the README.
try! draw(size: 256, inset: 0.1).write(to: root.appendingPathComponent("demo/icon.png"))
print("wrote macos/AppIcon.icns, windows/app/ClipStack.ico, demo/icon.png")
