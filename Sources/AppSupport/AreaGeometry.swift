import CoreGraphics
import Foundation

/// Pure geometry for the on-screen area picker. Everything the overlay
/// computes from mouse points lives here so it can be unit-tested without
/// a window: drag normalization, clamping, moving, the AppKit → capture
/// coordinate flip, and where the control strip goes.
///
/// Coordinate conventions:
/// - "screen-local bottom-left": what an AppKit view whose window covers
///   exactly one NSScreen sees — origin at the display's bottom-left, y up.
/// - "display-local top-left": what `CaptureCore.SourceGeometry.area`
///   consumes — origin at the display's top-left, y down, in points.
public enum AreaGeometry {

    /// Selections narrower/shorter than this are treated as a stray click.
    public static let minimumSide: CGFloat = 16

    /// Normalize a drag from `a` to `b` (either direction) into a rect
    /// clamped to `bounds`, snapped to whole points. Returns nil when the
    /// result is smaller than `minimumSide` on either axis.
    public static func selection(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect? {
        let raw = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y))
        let clamped = raw.intersection(bounds)
        guard !clamped.isNull else { return nil }
        let snapped = snap(clamped)
        guard snapped.width >= minimumSide, snapped.height >= minimumSide else { return nil }
        return snapped
    }

    /// Translate a selection by `delta`, keeping it fully inside `bounds`.
    public static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var out = rect.offsetBy(dx: delta.width, dy: delta.height)
        out.origin.x = min(max(bounds.minX, out.minX), max(bounds.minX, bounds.maxX - out.width))
        out.origin.y = min(max(bounds.minY, out.minY), max(bounds.minY, bounds.maxY - out.height))
        return snap(out)
    }

    /// Round the origin and size to whole points (the capture works in
    /// integral points; a half-point edge would blur every frame).
    public static func snap(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX.rounded(), y: rect.minY.rounded(),
            width: rect.width.rounded(), height: rect.height.rounded())
    }

    /// AppKit gives window frames in a global space whose origin is the
    /// primary display's bottom-left; subtract the screen's origin to get
    /// screen-local bottom-left coordinates.
    public static func screenLocal(_ globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    /// Flip a screen-local bottom-left rect into display-local top-left
    /// points (`SourceGeometry.area`'s input).
    public static func displayLocalTopLeft(_ rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX, y: screenHeight - rect.maxY,
            width: rect.width, height: rect.height)
    }

    /// The inverse of `displayLocalTopLeft`, for drawing a stored area
    /// back onto an AppKit view.
    public static func screenLocalBottomLeft(_ rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX, y: screenHeight - rect.maxY,
            width: rect.width, height: rect.height)
    }

    /// Where the Record/Cancel strip sits (bottom-left origin): centered
    /// under the selection with a small gap, flipped above it when there is
    /// no room below, and always kept inside `bounds`.
    public static func stripOrigin(
        for selection: CGRect, stripSize: CGSize, within bounds: CGRect, gap: CGFloat = 10
    ) -> CGPoint {
        var x = selection.midX - stripSize.width / 2
        x = min(max(bounds.minX + gap, x), bounds.maxX - stripSize.width - gap)
        var y = selection.minY - gap - stripSize.height
        if y < bounds.minY + gap {
            y = selection.maxY + gap
            if y + stripSize.height > bounds.maxY - gap {
                // Neither side fits (near-full-screen selection): tuck it
                // inside the selection's bottom edge.
                y = selection.minY + gap
            }
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// "1280 × 720".
    public static func sizeLabel(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }
}
