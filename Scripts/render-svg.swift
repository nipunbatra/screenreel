// Render an SVG to a PNG at an exact pixel size with AppKit (CoreSVG), so the
// brand pipeline has no dependency beyond macOS itself.
//
// usage: swift Scripts/render-svg.swift <in.svg> <out.png> <width> [height]
//                                       [--crop x y w h]
//
// --crop maps the given region of the SVG's user space onto the whole output
// (used to render the 824 px icon stage without its transparent margin).
//
// CoreSVG caveats (verified 2026-09): it renders gradients, clipPath, mask,
// opacity and plain feGaussianBlur like librsvg/browsers, but it ignores
// feOffset/feMerge/feColorMatrix/feDropShadow/mix-blend-mode and mis-blurs a
// filter applied directly to a stroked path (wrap the stroke in a <g>).
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: render-svg.swift <in.svg> <out.png> <width> [height] [--crop x y w h]\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
guard let width = Int(args[3]), width > 0 else { exit(2) }
var height = width
var rest = Array(args.dropFirst(4))
if let first = rest.first, let h = Int(first) {
    height = h
    rest.removeFirst()
}
var crop: CGRect?
if rest.first == "--crop", rest.count == 5,
   let x = Double(rest[1]), let y = Double(rest[2]), let w = Double(rest[3]), let h = Double(rest[4]) {
    crop = CGRect(x: x, y: y, width: w, height: h)
    rest.removeFirst(5)
}
guard rest.isEmpty else { exit(2) }

guard let image = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("cannot load \(inputURL.path)\n".utf8))
    exit(1)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context
context.cgContext.interpolationQuality = .high
context.cgContext.setShouldAntialias(true)

let imageSize = image.size
var destination = NSRect(x: 0, y: 0, width: width, height: height)
if let crop {
    // Scale the whole image so that `crop` fills the output; AppKit's origin
    // is bottom-left, SVG's is top-left.
    let kx = CGFloat(width) / crop.width
    let ky = CGFloat(height) / crop.height
    destination = NSRect(
        x: -crop.minX * kx,
        y: -(imageSize.height - crop.maxY) * ky,
        width: imageSize.width * kx,
        height: imageSize.height * ky)
}
image.draw(in: destination, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: outputURL)
} catch {
    FileHandle.standardError.write(Data("cannot write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
