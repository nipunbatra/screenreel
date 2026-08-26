import Foundation

/// Pure math turning a user's source selection into capture dimensions,
/// the point→pixel scale, and the event offset — extracted from the UI so
/// every branch is unit-tested. All inputs are in display points except
/// where named `Px`.
public enum SourceGeometry {

    public struct Resolved: Equatable, Sendable {
        public var widthPx: Int
        public var heightPx: Int
        /// Pixels-per-point of the capture (1 for standard/1× quality).
        public var scale: Double
        /// Display-local event pixels minus this offset = source pixels.
        public var eventOffsetXPx: Double
        public var eventOffsetYPx: Double
        /// Clamped area rect (area kind only), in display points.
        public var areaRect: AreaRect?
    }

    /// Round down to an even pixel count (encoders require even dims),
    /// never below 2.
    public static func evenPixels(_ value: Double) -> Int {
        max(2, Int(value) / 2 * 2)
    }

    /// The capture scale for a display: its native backing scale, or 1 for
    /// standard-quality (1×) capture.
    public static func captureScale(
        nativeWidthPx: Int, widthPoints: Int, native: Bool
    ) -> Double {
        guard native else { return 1 }
        return Double(nativeWidthPx) / Double(max(1, widthPoints))
    }

    public static func display(
        widthPoints: Int, heightPoints: Int, scale: Double
    ) -> Resolved {
        Resolved(
            widthPx: evenPixels(Double(widthPoints) * scale),
            heightPx: evenPixels(Double(heightPoints) * scale),
            scale: scale,
            eventOffsetXPx: 0, eventOffsetYPx: 0, areaRect: nil)
    }

    /// Area selection clamped inside the display; a degenerate request
    /// still yields a legal (≥16 pt) rect.
    public static func area(
        requested: AreaRect, displayWidthPoints: Int, displayHeightPoints: Int,
        scale: Double
    ) -> Resolved {
        let maxW = Double(displayWidthPoints)
        let maxH = Double(displayHeightPoints)
        let x = min(max(0, requested.x), max(0, maxW - 16))
        let y = min(max(0, requested.y), max(0, maxH - 16))
        let w = min(max(16, requested.width), maxW - x)
        let h = min(max(16, requested.height), maxH - y)
        let rect = AreaRect(x: x, y: y, width: w, height: h)
        return Resolved(
            widthPx: evenPixels(w * scale),
            heightPx: evenPixels(h * scale),
            scale: scale,
            eventOffsetXPx: x * scale,
            eventOffsetYPx: y * scale,
            areaRect: rect)
    }

    /// Window capture: dimensions from the window's point size at the
    /// capture scale; the event offset maps display-local pixels into
    /// window-local pixels (both computed from global points).
    public static func window(
        frame: CGRect, displayBounds: CGRect, scale: Double
    ) -> Resolved {
        Resolved(
            widthPx: evenPixels(frame.width * scale),
            heightPx: evenPixels(frame.height * scale),
            scale: scale,
            eventOffsetXPx: (frame.minX - displayBounds.minX) * scale,
            eventOffsetYPx: (frame.minY - displayBounds.minY) * scale,
            areaRect: nil)
    }

    /// Application capture renders on the full display canvas.
    public static func application(
        widthPoints: Int, heightPoints: Int, scale: Double
    ) -> Resolved {
        display(widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
    }

    /// A centered area of the requested size, clamped to the display.
    public static func centeredArea(
        width: Double, height: Double,
        displayWidthPoints: Int, displayHeightPoints: Int
    ) -> AreaRect {
        let w = min(width, Double(displayWidthPoints))
        let h = min(height, Double(displayHeightPoints))
        return AreaRect(
            x: (Double(displayWidthPoints) - w) / 2,
            y: (Double(displayHeightPoints) - h) / 2,
            width: w, height: h)
    }
}
