import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import PreviewEngine
import QuartzCore
import SwiftUI

/// One composed preview frame handed from the composition actor to the Metal
/// surface. `CIImage` is an immutable recipe whose inputs (decoded pixel
/// buffers, sprites) are retained and never written again, so sharing it
/// across actors and queues is safe; the wrapper exists to state that.
struct ComposedFrame: @unchecked Sendable {
    let image: CIImage
    /// The canvas the composition evaluated — `image.extent.size`, captured
    /// so the surface can aspect-fit without touching the image.
    let canvasSize: SIMD2<Double>
    let timeNs: Int64
}

/// Where the player pushes frames. The Metal view registers itself on mount;
/// while no sink is attached frames are kept as `latestFrame` and presented
/// the moment one appears.
@MainActor
protocol PreviewFrameSink: AnyObject {
    func present(_ frame: ComposedFrame)
    /// Harness-only readback of the last frame (window snapshots cannot
    /// capture CAMetalLayer contents). Never used on the interactive path.
    func snapshotImage() -> CGImage?
}

/// Draws composed frames into a `CAMetalLayer` on a private serial queue.
/// Zero CPU readback: the CIImage is rendered straight into the drawable's
/// texture and presented. At most one render is in flight; a frame that
/// arrives while one is being drawn replaces any still-waiting frame
/// (latest wins), so playback never queues up behind the GPU.
///
/// Concurrency: `@unchecked Sendable` because every mutable field is guarded
/// by `lock`, the Metal and Core Image objects are touched only from
/// `queue` (`CAMetalLayer.nextDrawable` and `CIContext` are thread-safe by
/// contract), and the layer's geometry properties are written by the owning
/// view on the main thread — a property change racing a draw only means one
/// frame presents at the previous size and the view immediately redraws.
final class MetalPreviewRenderer: @unchecked Sendable {
    let device: MTLDevice
    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let backdrop: CIImage
    /// Corner radius in points; scaled by the layer's contentsScale when
    /// the corners are painted into the drawable.
    private let cornerRadius: CGFloat
    private let onPresented: @Sendable (Int64) -> Void
    private let queue = DispatchQueue(label: "com.nipunbatra.screenreel.preview.render", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: ComposedFrame?
    private var last: ComposedFrame?
    private var jobScheduled = false

    init?(
        layer: CAMetalLayer, backdrop: CIColor, cornerRadius: CGFloat,
        onPresented: @escaping @Sendable (Int64) -> Void
    ) {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.layer = layer
        self.commandQueue = commandQueue
        // Same options as the exporter's context: every frame differs, so
        // intermediate caching only costs memory.
        self.context = CIContext(
            mtlDevice: device,
            options: [.cacheIntermediates: false, .name: "preview"])
        self.backdrop = CIImage(color: backdrop)
        self.cornerRadius = cornerRadius
        self.onPresented = onPresented
    }

    func present(_ frame: ComposedFrame) {
        lock.lock()
        pending = frame
        let schedule = !jobScheduled
        if schedule { jobScheduled = true }
        lock.unlock()
        guard schedule else { return }
        queue.async { [self] in drainPending() }
    }

    /// Re-present the last frame (the surface was resized or rescaled).
    func redraw() {
        lock.lock()
        let frame = last
        lock.unlock()
        if let frame { present(frame) }
    }

    private func drainPending() {
        while true {
            lock.lock()
            let next = pending
            pending = nil
            if next == nil { jobScheduled = false }
            lock.unlock()
            guard let next else { return }
            draw(next)
        }
    }

    /// Harness diagnostics (atomic enough for a report line).
    private(set) var presentedCount = 0
    private(set) var nilDrawableCount = 0

    private func draw(_ frame: ComposedFrame) {
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        guard let drawable = layer.nextDrawable() else {
            lock.lock(); nilDrawableCount += 1; lock.unlock()
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(frame, into: drawable.texture, size: size, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        lock.lock(); presentedCount += 1; lock.unlock()
        let timeNs = frame.timeNs
        let onPresented = self.onPresented
        commandBuffer.addCompletedHandler { _ in onPresented(timeNs) }
        commandBuffer.commit()
        // One render in flight: the next frame is encoded only after this
        // one has finished on the GPU (this is the private render queue,
        // so blocking here never touches the main thread).
        commandBuffer.waitUntilCompleted()
        lock.lock()
        last = frame
        lock.unlock()
    }

    /// The one encode path: aspect-fit the canvas into the target over the
    /// backdrop colour so every pixel is written (no stale contents in
    /// rounding slivers) and the result is opaque. Drawables and the
    /// harness's offscreen snapshot texture go through this same function.
    ///
    /// The destination is marked flipped: Core Image's image space has its
    /// origin at the bottom-left, but a Metal texture's first row is what
    /// the layer shows at the TOP. Unflipped (the `render(_:to:…)` default)
    /// the base row would hold logical y = 0.5 — the bottom of the frame —
    /// and the preview would display upside down (CIRenderDestination.h).
    private func encode(
        _ frame: ComposedFrame, into texture: MTLTexture, size: CGSize,
        commandBuffer: MTLCommandBuffer
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        let transform = PreviewFit.transform(
            canvasSize: frame.canvasSize,
            drawableSize: SIMD2(size.width, size.height))
        let backdropFill = backdrop.cropped(to: bounds)
        var image = frame.image
            .transformed(by: transform)
            .composited(over: backdropFill)
        // Rounded corners painted here (see the view: the layer itself
        // stays unmasked). Outside the rounded rect the drawable holds the
        // backdrop colour, which is what surrounds the surface anyway.
        let radius = cornerRadius * layer.contentsScale
        if radius > 0.5 {
            let generator = CIFilter.roundedRectangleGenerator()
            generator.extent = bounds
            generator.radius = Float(radius)
            generator.color = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            if let mask = generator.outputImage?.cropped(to: bounds) {
                image = image.applyingFilter(
                    "CIBlendWithAlphaMask",
                    parameters: [
                        kCIInputBackgroundImageKey: backdropFill,
                        kCIInputMaskImageKey: mask,
                    ])
            }
        }
        let destination = CIRenderDestination(
            mtlTexture: texture, commandBuffer: commandBuffer)
        destination.isFlipped = true
        destination.colorSpace = colorSpace
        destination.alphaMode = .premultiplied
        // Only failure mode is an unsupported destination, which cannot
        // happen for a bgra8Unorm render target; the frame is simply
        // skipped rather than crashing the editor.
        _ = try? context.startTask(
            toRender: image, from: bounds, to: destination, at: .zero)
    }

    /// Readback for the autopilot's window snapshots only: the last frame
    /// rendered through `encode` into an offscreen texture of the drawable's
    /// size, then copied out — exactly the pixels the layer shows, in the
    /// same orientation. Runs on the caller's thread with its own command
    /// buffer (`MTLCommandQueue` and `CIContext` are thread-safe), so the
    /// main thread never waits on the render queue. Never called on the
    /// interactive path.
    func snapshotImage() -> CGImage? {
        lock.lock()
        let frame = last ?? pending
        lock.unlock()
        let size = layer.drawableSize
        guard let frame, size.width >= 1, size.height >= 1 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }
        encode(frame, into: texture, size: size, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // Texture row 0 is the top row on screen; CGImage rows run
        // top-down too, so no flip.
        return CGImage(
            width: texture.width, height: texture.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

/// The preview surface: an `NSView` hosting a `CAMetalLayer`. It is sized
/// by SwiftUI to the aspect-fitted canvas rect and reports its point
/// size/backing scale so frames render at the surface's real pixel size.
/// It draws nothing itself — contents (rounded corners included) come from
/// the renderer.
///
/// Direct manipulation is recognized here in AppKit (SwiftUI gestures on an
/// ancestor do not fire over a platform view): a click that barely moves is
/// a tap, a press that travels ≥ 24 pt is a drag — the same thresholds the
/// previous `SpatialTapGesture` / `DragGesture(minimumDistance: 24)` pair
/// used. Points are reported top-left-origin in the view's own points.
final class MetalPreviewNSView: NSView, PreviewFrameSink {
    private let metalLayer = CAMetalLayer()
    private(set) var renderer: MetalPreviewRenderer?
    weak var player: PreviewPlayer?
    /// Corner radius shared with the SwiftUI border/shadow shapes around it.
    static let cornerRadius: CGFloat = 6
    static let tapSlop: CGFloat = 4
    static let dragMinimumDistance: CGFloat = 24
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onDragEnd: ((CGPoint, CGSize) -> Void)?
    private var pressStart: CGPoint?
    private var dragExceededMinimum = false

    init(backdrop: NSColor, onPresented: @escaping @Sendable (Int64) -> Void) {
        super.init(frame: .zero)
        // Layer-HOSTING, not layer-backed: assigning the layer before
        // `wantsLayer` tells AppKit the view owns this layer outright —
        // AppKit only keeps its geometry in step with the view and never
        // manages its contents.
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Core Image writes the drawable's texture directly, which requires
        // it not be framebuffer-only. Snapshots read back from the CIImage,
        // never from the drawable.
        metalLayer.framebufferOnly = false
        // Opaque and unmasked on purpose: the rounded corners are painted
        // INTO the drawable (encode masks the frame over the backdrop
        // colour). A CAMetalLayer with cornerRadius + masksToBounds is
        // composited through an offscreen copy that the compositor only
        // refreshes when a transaction dirties the layer — and presenting a
        // drawable does not — so the preview froze on its first frame.
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = backdrop.cgColor
        let srgb = backdrop.usingColorSpace(.sRGB) ?? backdrop
        renderer = MetalPreviewRenderer(
            layer: metalLayer,
            backdrop: CIColor(
                red: srgb.redComponent, green: srgb.greenComponent,
                blue: srgb.blueComponent),
            cornerRadius: Self.cornerRadius,
            onPresented: onPresented)
        metalLayer.device = renderer?.device
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { /* contents come from the Metal drawable */ }

    // MARK: Direct manipulation

    /// Window point → this view's points with a top-left origin (matches
    /// the fit math and the canvas fraction convention).
    private func localPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    /// Harness diagnostics: presses seen by this view.
    private(set) var mouseDownCount = 0

    /// A click on the preview counts even when the window is not key —
    /// AppKit otherwise swallows it as the activation click, and aiming a
    /// zoom is exactly the kind of thing done right after switching back.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
        pressStart = localPoint(event)
        dragExceededMinimum = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart else { return }
        let point = localPoint(event)
        if hypot(point.x - start.x, point.y - start.y) >= Self.dragMinimumDistance {
            dragExceededMinimum = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressStart else { return }
        pressStart = nil
        let point = localPoint(event)
        let distance = hypot(point.x - start.x, point.y - start.y)
        if dragExceededMinimum || distance >= Self.dragMinimumDistance {
            onDragEnd?(point, bounds.size)
        } else if distance <= Self.tapSlop {
            onTap?(point, bounds.size)
        }
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            renderer?.redraw()
        }
        player?.setPreviewSurface(pointSize: bounds.size, displayScale: scale)
    }

    // MARK: PreviewFrameSink

    func present(_ frame: ComposedFrame) {
        renderer?.present(frame)
    }

    func snapshotImage() -> CGImage? {
        renderer?.snapshotImage()
    }

    /// The surface inside a window's view tree (harness snapshots overlay
    /// the frame at its rect, since `cacheDisplay` skips Metal contents).
    static func find(in view: NSView) -> MetalPreviewNSView? {
        findAll(in: view).first
    }

    static func findAll(in view: NSView) -> [MetalPreviewNSView] {
        var found: [MetalPreviewNSView] = []
        if let surface = view as? MetalPreviewNSView { found.append(surface) }
        for child in view.subviews { found += findAll(in: child) }
        return found
    }

    /// Harness diagnostics: the layer/window state that decides whether
    /// presented drawables can reach the screen.
    var diagnostics: String {
        let backing = layer.map { $0 === metalLayer ? "metal" : String(describing: type(of: $0)) } ?? "nil"
        return "backing=\(backing) drawable=\(Int(metalLayer.drawableSize.width))x\(Int(metalLayer.drawableSize.height))"
            + " layerBounds=\(Int(metalLayer.bounds.width))x\(Int(metalLayer.bounds.height))"
            + " scale=\(metalLayer.contentsScale) window=\(window != nil)"
            + " hidden=\(isHiddenOrHasHiddenAncestor) layerHidden=\(metalLayer.isHidden)"
            + " opacity=\(metalLayer.opacity) superlayer=\(metalLayer.superlayer != nil)"
            + " contents=\(metalLayer.contents != nil) device=\(metalLayer.device != nil)"
            + " presented=\(renderer?.presentedCount ?? -1) nilDrawables=\(renderer?.nilDrawableCount ?? -1)"
    }
}

/// SwiftUI host for the Metal surface. `updateNSView` deliberately reads no
/// observable state: frames flow player → sink → GPU without a SwiftUI
/// update per frame.
struct MetalPreviewSurface: NSViewRepresentable {
    let player: PreviewPlayer
    /// Tap / drag-release in the surface's top-left-origin points plus its
    /// size, for the fit math.
    let onTap: (CGPoint, CGSize) -> Void
    let onDragEnd: (CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> MetalPreviewNSView {
        let view = MetalPreviewNSView(
            backdrop: NSColor(Color.canvasBackdrop),
            onPresented: { [weak player] timeNs in
                Task { @MainActor in player?.notePresented(timeNs: timeNs) }
            })
        view.player = player
        view.onTap = onTap
        view.onDragEnd = onDragEnd
        player.attachFrameSink(view)
        return view
    }

    func updateNSView(_ nsView: MetalPreviewNSView, context: Context) {
        nsView.onTap = onTap
        nsView.onDragEnd = onDragEnd
        if nsView.player !== player {
            nsView.player?.detachFrameSink(nsView)
            nsView.player = player
            player.attachFrameSink(nsView)
        }
    }

    static func dismantleNSView(_ nsView: MetalPreviewNSView, coordinator: ()) {
        nsView.player?.detachFrameSink(nsView)
    }
}
