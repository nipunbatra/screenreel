// App icon generator: original artwork drawn with CoreGraphics, no external
// assets. Usage: swift Scripts/make-icon.swift <output.icns>
//
// Design: "Zoomwell" (design consult 2026-08-25) — a screen collapsing
// through an offset luminous zoom frame into a coral focus viewport:
// screen → zoom → focus in one silhouette, instead of a generic record dot.
// Geometry is specified on a 1024×1024 canvas, CG coordinates (origin
// bottom-left); every shape scales with `s`.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

private func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0))!
}

func draw(into ctx: CGContext, size: Int) {
    let s = CGFloat(size) / 1024.0
    ctx.interpolationQuality = .high
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(
            roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
            cornerWidth: r * s, cornerHeight: r * s, transform: nil)
    }
    /// Fill `path` with a linear gradient, optionally under a shadow.
    func fill(
        _ path: CGPath, from: CGPoint, to: CGPoint,
        stops: [(CGFloat, CGColor)],
        shadow: (color: CGColor, blur: CGFloat, dy: CGFloat)? = nil,
        alpha: CGFloat = 1
    ) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if let shadow {
            // Shadow pass: opaque silhouette casts it, then the gradient
            // paints over inside a transparency layer.
            ctx.setShadow(
                offset: CGSize(width: 0, height: shadow.dy * s),
                blur: shadow.blur * s, color: shadow.color)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(
            gradient(stops),
            start: CGPoint(x: from.x * s, y: from.y * s),
            end: CGPoint(x: to.x * s, y: to.y * s),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // 1. Plate.
    let plate = rr(100, 100, 824, 824, 185)
    fill(
        plate, from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100),
        stops: [(0, color(0x243650)), (0.48, color(0x111B2B)), (1, color(0x070B12))],
        shadow: (color(0x000000, 0.35), 32, -16))

    // 2. Plate bloom (clipped).
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([
            (0, color(0x7EABE0, 0.18)), (0.62, color(0x7EABE0, 0.05)),
            (1, color(0x7EABE0, 0)),
        ]),
        startCenter: CGPoint(x: 430 * s, y: 748 * s), startRadius: 0,
        endCenter: CGPoint(x: 430 * s, y: 748 * s), endRadius: 430 * s,
        options: [])
    ctx.restoreGState()

    // 3. Plate edge.
    ctx.saveGState()
    ctx.addPath(rr(102, 102, 820, 820, 183))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(4 * s)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Screen glass.
    fill(
        rr(268, 350, 488, 320, 82),
        from: CGPoint(x: 512, y: 670), to: CGPoint(x: 512, y: 350),
        stops: [(0, color(0x142A3C)), (1, color(0x081019))])

    // 5. Main screen frame (even-odd ring).
    let mainFrame = CGMutablePath()
    mainFrame.addPath(rr(216, 296, 592, 424, 120))
    mainFrame.addPath(rr(268, 350, 488, 320, 82))
    fill(
        mainFrame, from: CGPoint(x: 240, y: 700), to: CGPoint(x: 790, y: 320),
        stops: [(0, color(0xFFFFFF)), (0.42, color(0xD8EDF0)), (1, color(0x91B4C2))],
        shadow: (color(0x000000, 0.42), 32, -18))

    // 6. Zoom frame (luminous mint→violet ring).
    let zoomFrame = CGMutablePath()
    zoomFrame.addPath(rr(352, 390, 356, 244, 70))
    zoomFrame.addPath(rr(390, 428, 280, 168, 44))
    fill(
        zoomFrame, from: CGPoint(x: 352, y: 390), to: CGPoint(x: 708, y: 634),
        stops: [(0, color(0x55E5DD)), (1, color(0x7770FF))],
        shadow: (color(0x000000, 0.22), 12, -6),
        alpha: 0.88)

    // 7. Focus viewport (coral).
    fill(
        rr(492, 456, 174, 126, 42),
        from: CGPoint(x: 579, y: 582), to: CGPoint(x: 579, y: 456),
        stops: [(0, color(0xFF7568)), (0.45, color(0xF23E50)), (1, color(0xC91439))],
        shadow: (color(0xF23E50, 0.45), 28, 0))

    // 8. Focus bezel + 9. micro-highlight (premium detail, ≥32 px only).
    if size >= 32 {
        ctx.saveGState()
        ctx.addPath(rr(494, 458, 170, 122, 40))
        ctx.setStrokeColor(color(0xFFFFFF, 0.18))
        ctx.setLineWidth(4 * s)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(rr(514, 548, 130, 16, 8))
        ctx.setFillColor(color(0xFFFFFF, 0.22))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func renderPNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }
    draw(into: context, size: size)
    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("aks-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

for base in [16, 32, 128, 256, 512] {
    try renderPNG(
        size: base,
        to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(
        size: base * 2,
        to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(outputURL.path)")
