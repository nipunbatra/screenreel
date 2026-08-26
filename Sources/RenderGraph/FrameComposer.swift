import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MotionEngine
import TimelineCore

/// Deterministic frame composition (`docs/TECHNICAL_DESIGN.md` §5,
/// `docs/MOTION_ENGINE.md` §8). Preview and export both call this exact
/// evaluator — quality may differ (proxy inputs, render target size), but
/// geometry, timing, and event evaluation may not.
///
/// Model: the *screen card* is the padded, aspect-fitted rectangle on the
/// canvas; it does not move. The zoom camera selects a viewport of the source
/// (scale about a clamped focal point) that is mapped onto the card, so
/// content magnifies inside the card and crops at its rounded corners. The
/// cursor anchor goes through the same source→card transform, then the sprite
/// is drawn sharp at output resolution.
public struct FrameComposer: Sendable {
    public struct Geometry: Sendable, Equatable {
        /// Source pixel → canvas pixel mapping for the current camera.
        public var contentScale: Double
        public var contentOffset: SIMD2<Double>
        /// The fixed screen-card rectangle on the canvas.
        public var cardOrigin: SIMD2<Double>
        public var cardSize: SIMD2<Double>

        public func canvasPoint(forSource point: SIMD2<Double>) -> SIMD2<Double> {
            point * contentScale + contentOffset
        }
    }

    public let style: FrameStyle
    public let outputSize: SIMD2<Double>
    public let sourceSize: SIMD2<Double>

    public init(style: FrameStyle, outputSize: SIMD2<Double>, sourceSize: SIMD2<Double>) {
        self.style = style
        self.outputSize = outputSize
        self.sourceSize = sourceSize
    }

    // MARK: - Geometry (pure math, unit-testable without Core Image)

    /// The screen-card rect and source→canvas mapping for a camera state.
    /// The camera focal is re-clamped here so spring overshoot can never
    /// reveal space beyond the source edges (`docs/MOTION_ENGINE.md` §7).
    public func geometry(camera: CameraState) -> Geometry {
        let minEdge = min(outputSize.x, outputSize.y)
        let pad = style.padding * minEdge
        let available = outputSize - SIMD2(2 * pad, 2 * pad)

        // Aspect-fit the source into the padded canvas.
        let fit = min(available.x / sourceSize.x, available.y / sourceSize.y)
        let cardSize = sourceSize * fit
        let cardOrigin = (outputSize - cardSize) / 2

        // Zoom viewport of the source mapped onto the card.
        let scale = max(1.0, camera.scale)
        let focal = ZoomGenerator.clampFocal(camera.focal, scale: scale, snapRatio: 0)
        let viewportSize = sourceSize / scale
        let viewportOrigin = focal * sourceSize - viewportSize / 2

        var contentScale = cardSize.x / viewportSize.x
        // Sub-0.2% residue from even-dimension snapping: treat as exactly 1
        // HERE, so geometry (offsets, cursor placement) and the raster
        // identity fast-path can never disagree about whether scaling
        // happened — the mismatch misplaced content by up to ~5 px at 2880w.
        if abs(contentScale - 1) <= 0.002 { contentScale = 1 }
        let contentOffset = cardOrigin - viewportOrigin * contentScale
        return Geometry(
            contentScale: contentScale,
            contentOffset: contentOffset,
            cardOrigin: cardOrigin,
            cardSize: cardSize)
    }

    // MARK: - Composition

    public struct Input {
        /// Raw screen frame in source pixels (bottom-left origin, CI space).
        public var screenImage: CIImage
        public var camera: CameraState
        public var cursor: CursorFrameState?
        /// Sprite in its own pixels, plus hotspot in sprite pixels
        /// (top-left origin) and the sprite's source-pixel display size.
        public var cursorSprite: CIImage?
        public var cursorHotspot: SIMD2<Double>
        public var cursorSpriteSourceSize: SIMD2<Double>
        public var cursorSizeMultiplier: Double
        /// Webcam frame in its own pixels; nil when there is no camera track
        /// or the frame is unavailable at this time.
        public var cameraImage: CIImage?
        public var cameraStyle: CameraStyle?
        /// Shortcut chips (label + fade progress 0…1), newest last,
        /// evaluated upstream. Rendered bottom-center over everything.
        public var keystrokeChips: [(text: String, progress: Double)] = []
        /// Live click ripples in SOURCE pixels with fade progress 0…1,
        /// evaluated upstream (one deterministic function for preview and
        /// export).
        public var clickRipples: [(position: SIMD2<Double>, progress: Double)] = []
        /// Camera-intro interpolation: 0 = fullscreen camera, 1 = normal
        /// corner PiP. The TIME→progress easing happens upstream (one
        /// place, shared by preview and export); the composer is linear in
        /// this value.
        public var cameraIntroProgress: Double = 1

        public init(
            screenImage: CIImage,
            camera: CameraState,
            cursor: CursorFrameState? = nil,
            cursorSprite: CIImage? = nil,
            cursorHotspot: SIMD2<Double> = .zero,
            cursorSpriteSourceSize: SIMD2<Double> = .zero,
            cursorSizeMultiplier: Double = 1,
            cameraImage: CIImage? = nil,
            cameraStyle: CameraStyle? = nil
        ) {
            self.screenImage = screenImage
            self.camera = camera
            self.cursor = cursor
            self.cursorSprite = cursorSprite
            self.cursorHotspot = cursorHotspot
            self.cursorSpriteSourceSize = cursorSpriteSourceSize
            self.cursorSizeMultiplier = cursorSizeMultiplier
            self.cameraImage = cameraImage
            self.cameraStyle = cameraStyle
        }
    }

    /// The camera PiP rect in *top-left* canvas coordinates for a given zoom
    /// scale — pure math so tests can pin the geometry without Core Image.
    public func cameraRect(
        style camStyle: CameraStyle, cameraSize: SIMD2<Double>, zoomScale: Double,
        introProgress: Double = 1
    ) -> CGRect {
        let minEdge = min(outputSize.x, outputSize.y)
        // Shrink continuously as the zoom engages so the camera gets out of
        // the way of magnified content (fully shrunk by 1.5×).
        let zoomT = min(1.0, max(0.0, (zoomScale - 1.0) / 0.5))
        let pipScale = 1.0 + (camStyle.zoomedScale - 1.0) * zoomT
        var width = max(1.0, camStyle.size * minEdge * pipScale)
        let aspect = camStyle.shape == .circle
            ? 1.0
            : (cameraSize.x > 0 ? cameraSize.y / cameraSize.x : 9.0 / 16.0)
        var height = width * aspect
        let margin = camStyle.margin * minEdge
        // A portrait camera (Continuity Camera held vertically) can make
        // the PiP taller than the canvas — fit-clamp both dimensions so it
        // never draws off-screen (found by geometry fuzz).
        let fit = min(
            1.0,
            max(1.0, outputSize.x - 2 * margin) / width,
            max(1.0, outputSize.y - 2 * margin) / height)
        width *= fit
        height *= fit
        let x: Double
        let y: Double
        switch camStyle.corner {
        case .topLeft: x = margin; y = margin
        case .topRight: x = outputSize.x - margin - width; y = margin
        case .bottomLeft: x = margin; y = outputSize.y - margin - height
        case .bottomRight:
            x = outputSize.x - margin - width
            y = outputSize.y - margin - height
        }
        let pip = CGRect(x: x, y: y, width: width, height: height)
        let t = min(1.0, max(0.0, introProgress))
        guard t < 1 else { return pip }
        // Fullscreen opening: aspect-FILL the canvas (cover, center-crop),
        // then interpolate every rect component toward the corner PiP.
        let fillScale = max(
            outputSize.x / max(cameraSize.x, 1),
            outputSize.y / max(cameraSize.y, 1))
        let fullWidth = cameraSize.x * fillScale
        let fullHeight = cameraSize.y * fillScale
        let full = CGRect(
            x: (outputSize.x - fullWidth) / 2,
            y: (outputSize.y - fullHeight) / 2,
            width: fullWidth, height: fullHeight)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return CGRect(
            x: lerp(full.minX, pip.minX),
            y: lerp(full.minY, pip.minY),
            width: lerp(full.width, pip.width),
            height: lerp(full.height, pip.height))
    }

    /// Compose one output frame. Coordinates in this function are Core Image
    /// space (origin bottom-left); recorded cursor positions are top-left, so
    /// the y-axis flips at the anchor conversion.
    public func compose(_ input: Input) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
        let geometry = geometry(camera: input.camera)
        let cardRect = CGRect(
            x: geometry.cardOrigin.x,
            y: outputSize.y - geometry.cardOrigin.y - geometry.cardSize.y,
            width: geometry.cardSize.x,
            height: geometry.cardSize.y)
        let cornerRadius = style.cornerRadius * min(geometry.cardSize.x, geometry.cardSize.y)

        var result = backgroundImage(canvasRect: canvasRect)

        // Shadow under the card.
        if style.shadowOpacity > 0.001, style.shadowRadius > 0.001 {
            let shadowBlur = style.shadowRadius * min(outputSize.x, outputSize.y)
            let shadowShape = roundedRectImage(
                rect: cardRect, radius: cornerRadius,
                color: CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
            let blurred = shadowShape
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": shadowBlur / 2])
            result = blurred.composited(over: result)
        }

        // Screen content: source → card transform, cropped to the card and
        // masked by its rounded corners. Scaling uses Lanczos — the default
        // bilinear sampling visibly softens text on the ~0.9× padded-card
        // downscale (and on zoom upscales); Lanczos keeps edges tight.
        var content = scaled(input.screenImage, by: geometry.contentScale)
            .transformed(by: CGAffineTransform(
                translationX: geometry.contentOffset.x,
                y: outputSize.y - geometry.contentOffset.y
                    - sourceSize.y * geometry.contentScale))
            .cropped(to: cardRect)
        if cornerRadius > 0.5 {
            let mask = roundedRectImage(
                rect: cardRect, radius: cornerRadius,
                color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            content = content.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ])
        }
        result = content.composited(over: result)

        // Click ripples: expanding, fading rings anchored through the same
        // transform as the cursor, drawn beneath it and CLIPPED to the
        // screen card — a click near the edge (or outside a zoom viewport)
        // must not paint arcs onto the wallpaper.
        var rippleLayer: CIImage?
        for ripple in input.clickRipples {
            let t = min(1.0, max(0.0, ripple.progress))
            let anchor = geometry.canvasPoint(forSource: ripple.position)
            let center = CGPoint(x: anchor.x, y: outputSize.y - anchor.y)
            let scaleRef = geometry.contentScale * input.cursorSizeMultiplier
            let radius = (16.0 + 34.0 * t) * scaleRef
            let thickness = max(1.5, 3.5 * scaleRef)
            let alpha = (1.0 - t) * 0.5
            guard radius > 0.5, alpha > 0.01 else { continue }
            let color = CIColor(red: 1, green: 1, blue: 1, alpha: alpha)
            let outer = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(x: center.x, y: center.y),
                    "inputRadius0": NSNumber(value: Double(radius) - thickness),
                    "inputRadius1": NSNumber(value: Double(radius)),
                    "inputColor0": color,
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
                ])?.outputImage
            let hole = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(x: center.x, y: center.y),
                    "inputRadius0": NSNumber(value: max(0, Double(radius) - thickness * 2)),
                    "inputRadius1": NSNumber(value: Double(radius) - thickness),
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
                ])?.outputImage
            if let outer, let hole {
                // Disc minus inner disc = ring with soft edges.
                let ring = outer.applyingFilter(
                    "CISourceOutCompositing",
                    parameters: [kCIInputBackgroundImageKey: hole])
                let box = CGRect(
                    x: center.x - radius - 2, y: center.y - radius - 2,
                    width: radius * 2 + 4, height: radius * 2 + 4)
                let cropped = ring.cropped(to: box)
                rippleLayer = rippleLayer.map { cropped.composited(over: $0) }
                    ?? cropped
            }
        }
        if var ripples = rippleLayer {
            ripples = ripples.cropped(to: cardRect)
            if cornerRadius > 0.5 {
                let mask = roundedRectImage(
                    rect: cardRect, radius: cornerRadius,
                    color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                ripples = ripples.applyingFilter(
                    "CIBlendWithAlphaMask",
                    parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask,
                    ])
            }
            result = ripples.composited(over: result)
        }

        // Cursor: anchor through the same transform, sprite sharp at output
        // resolution, click squash about the hotspot.
        if let cursor = input.cursor, cursor.visible,
            let sprite = input.cursorSprite,
            input.cursorSpriteSourceSize.x > 0,
            sprite.extent.width > 0
        {
            let anchor = geometry.canvasPoint(forSource: cursor.position)
            let anchorCI = SIMD2(anchor.x, outputSize.y - anchor.y)
            let displaySize = input.cursorSpriteSourceSize
                * geometry.contentScale * input.cursorSizeMultiplier * cursor.scale
            let spriteScale = displaySize.x / sprite.extent.width
            let hotspotOffset = SIMD2(
                input.cursorHotspot.x * spriteScale,
                // Sprite hotspot is top-left based; CI is bottom-left.
                displaySize.y - input.cursorHotspot.y * spriteScale)
            let transform = CGAffineTransform(
                translationX: anchorCI.x - hotspotOffset.x,
                y: anchorCI.y - hotspotOffset.y)
                .scaledBy(x: spriteScale, y: spriteScale)
            let placed = sprite.transformed(by: transform)
            result = placed.composited(over: result)
        }

        // Camera PiP on top of everything, anchored to a corner, shrinking
        // while zooms are active. The raw camera frame is aspect-filled into
        // the PiP rect and masked to its shape.
        if let cameraImage = input.cameraImage,
            let camStyle = input.cameraStyle, !camStyle.hidden,
            cameraImage.extent.width > 0, cameraImage.extent.height > 0
        {
            let rect = cameraRect(
                style: camStyle,
                cameraSize: SIMD2(cameraImage.extent.width, cameraImage.extent.height),
                zoomScale: max(1.0, input.camera.scale),
                introProgress: input.cameraIntroProgress)
            // Top-left rect → CI bottom-left rect.
            let pipRect = CGRect(
                x: rect.origin.x,
                y: outputSize.y - rect.origin.y - rect.height,
                width: rect.width, height: rect.height)
            var radius: Double
            switch camStyle.shape {
            case .circle: radius = min(pipRect.width, pipRect.height) / 2
            case .rounded: radius = 0.14 * min(pipRect.width, pipRect.height)
            case .square: radius = 0
            }
            // The fullscreen opening has no corner rounding; it rounds in
            // as the camera flies to its corner.
            radius *= min(1.0, max(0.0, input.cameraIntroProgress))

            if style.shadowOpacity > 0.001, style.shadowRadius > 0.001 {
                let shadowBlur = style.shadowRadius * min(outputSize.x, outputSize.y)
                let shadowShape = roundedRectImage(
                    rect: pipRect, radius: radius,
                    color: CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
                let blurred = shadowShape
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": shadowBlur / 3])
                result = blurred.composited(over: result)
            }

            // Aspect-fill: cover the PiP rect, center-cropped.
            var source = cameraImage
            if camStyle.mirrored {
                source = source
                    .transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                        .translatedBy(x: -source.extent.width - 2 * source.extent.origin.x, y: 0))
            }
            let fill = max(
                pipRect.width / source.extent.width,
                pipRect.height / source.extent.height)
            let scaled = self.scaled(source, by: fill)
            let placeOrigin = CGPoint(
                x: pipRect.midX - scaled.extent.width / 2 - scaled.extent.origin.x,
                y: pipRect.midY - scaled.extent.height / 2 - scaled.extent.origin.y)
            var pip = scaled
                .transformed(by: CGAffineTransform(
                    translationX: placeOrigin.x, y: placeOrigin.y))
                .cropped(to: pipRect)
            if radius > 0.5 {
                let mask = roundedRectImage(
                    rect: pipRect, radius: radius,
                    color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                pip = pip.applyingFilter(
                    "CIBlendWithAlphaMask",
                    parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask,
                    ])
            }
            result = pip.composited(over: result)
        }

        // Shortcut chips: dark rounded capsules with the pressed keys,
        // bottom-center, newest at the right, fading out with progress.
        if !input.keystrokeChips.isEmpty {
            let chipHeight = max(24.0, outputSize.y * 0.052)
            let fontSize = chipHeight * 0.52
            let gap = chipHeight * 0.3
            var rendered: [(image: CIImage, width: Double, alpha: Double)] = []
            for chip in input.keystrokeChips {
                guard let text = labelImage(chip.text, fontSize: fontSize)
                else { continue }
                let width = text.extent.width + chipHeight * 0.9
                let alpha = 1.0 - min(1.0, max(0.0, (chip.progress - 0.6) / 0.4))
                // Filter dead chips HERE: counting them in totalWidth but
                // skipping them in the draw loop off-centered the row for
                // the last frame of a chip's life.
                guard alpha > 0.01 else { continue }
                rendered.append((text, width, alpha))
            }
            let totalWidth = rendered.reduce(0.0) { $0 + $1.width }
                + gap * Double(max(0, rendered.count - 1))
            var x = (outputSize.x - totalWidth) / 2
            let y = outputSize.y * 0.06
            for chip in rendered {
                let rect = CGRect(
                    x: x, y: y, width: chip.width, height: chipHeight)
                let capsule = roundedRectImage(
                    rect: rect, radius: chipHeight / 2,
                    color: CIColor(
                        red: 0.06, green: 0.06, blue: 0.09,
                        alpha: 0.72 * chip.alpha))
                let label = chip.image
                    .transformed(by: CGAffineTransform(
                        translationX: rect.midX - chip.image.extent.midX,
                        y: rect.midY - chip.image.extent.midY))
                    .applyingFilter("CIColorMatrix", parameters: [
                        // Premultiplied: RGB must fade WITH alpha or the
                        // glyphs hold full brightness and pop off at the
                        // cutoff instead of fading.
                        "inputRVector": CIVector(x: chip.alpha, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: chip.alpha, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: chip.alpha, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: chip.alpha),
                    ])
                result = label
                    .composited(over: capsule.composited(over: result))
                x += chip.width + gap
            }
        }

        return result.cropped(to: canvasRect)
    }

    /// White CoreText label rasterized once per (text, size) and cached —
    /// chips repeat across hundreds of frames. Reference-type cache so the
    /// value-type composer can fill it from a non-mutating render call.
    private final class LabelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: CIImage] = [:]
        func get(_ key: String) -> CIImage? {
            lock.lock()
            defer { lock.unlock() }
            return store[key]
        }
        func set(_ key: String, _ image: CIImage) {
            lock.lock()
            store[key] = image
            lock.unlock()
        }
    }
    private let labelCache = LabelCache()
    private func labelImage(_ text: String, fontSize: Double) -> CIImage? {
        let key = "\(Int(fontSize * 4))|\(text)"
        if let cached = labelCache.get(key) { return cached }
        guard let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        else { return nil }
        let attributes =
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(
                    red: 1, green: 1, blue: 1, alpha: 1),
            ] as CFDictionary
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let width = Int(ceil(bounds.width)) + 4
        let height = Int(ceil(bounds.height)) + 4
        guard width > 4, height > 4,
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.textPosition = CGPoint(x: 2 - bounds.minX, y: 2 - bounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let ciImage = CIImage(cgImage: image)
        labelCache.set(key, ciImage)
        return ciImage
    }

    // MARK: - Primitive images

    /// High-quality uniform scale: Lanczos everywhere except identity.
    private func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        // Identity must be EXACT: near-1 residue is snapped to 1 where
        // contentScale is computed, so skipping here can never diverge
        // from the offsets computed alongside it.
        guard factor != 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(factor)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else {
            return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        return output
    }

    private func backgroundImage(canvasRect: CGRect) -> CIImage {
        switch style.background {
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: canvasRect)
        case .solid(let color):
            return CIImage(color: CIColor(
                red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
                .cropped(to: canvasRect)
        case .linearGradient(let top, let bottom):
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: canvasRect.midX, y: canvasRect.maxY)
            gradient.point1 = CGPoint(x: canvasRect.midX, y: canvasRect.minY)
            gradient.color0 = CIColor(
                red: top.red, green: top.green, blue: top.blue, alpha: top.alpha)
            gradient.color1 = CIColor(
                red: bottom.red, green: bottom.green, blue: bottom.blue, alpha: bottom.alpha)
            return (gradient.outputImage ?? CIImage.empty()).cropped(to: canvasRect)
        case .mesh(let base, let glow1, let glow2):
            // Deterministic two-light mesh over a darkened base: light 1
            // upper-left, light 2 lower-right, radii proportional to the
            // canvas diagonal — identical at every resolution.
            var result = CIImage(color: CIColor(
                red: base.red * 0.55, green: base.green * 0.55,
                blue: base.blue * 0.55, alpha: 1)).cropped(to: canvasRect)
            let diagonal = (canvasRect.width * canvasRect.width
                + canvasRect.height * canvasRect.height).squareRoot()
            func light(_ color: FrameStyle.Color, at point: CGPoint, radius: Double) -> CIImage {
                let filter = CIFilter.radialGradient()
                filter.center = point
                filter.radius0 = 0
                filter.radius1 = Float(radius)
                filter.color0 = CIColor(
                    red: color.red, green: color.green, blue: color.blue, alpha: 0.85)
                filter.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                return (filter.outputImage ?? CIImage.empty()).cropped(to: canvasRect)
            }
            let first = light(
                glow1,
                at: CGPoint(
                    x: canvasRect.minX + canvasRect.width * 0.22,
                    y: canvasRect.minY + canvasRect.height * 0.78),
                radius: diagonal * 0.52)
            let second = light(
                glow2,
                at: CGPoint(
                    x: canvasRect.minX + canvasRect.width * 0.82,
                    y: canvasRect.minY + canvasRect.height * 0.18),
                radius: diagonal * 0.46)
            result = first.applyingFilter(
                "CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result])
            result = second.applyingFilter(
                "CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result])
            return result.cropped(to: canvasRect)
        }
    }

    private func roundedRectImage(rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(max(0, radius))
        generator.color = color
        return (generator.outputImage ?? CIImage.empty()).cropped(
            to: rect.insetBy(dx: -1, dy: -1))
    }
}
