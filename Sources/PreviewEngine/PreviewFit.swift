import CoreGraphics
import Foundation

/// Pure geometry for the editor's preview surface: where a composed canvas
/// lands when aspect-fitted into a view, and how a pointer position in that
/// view maps back to a canvas fraction.
///
/// The preview no longer hands the UI a CGImage whose pixel size could be
/// inspected; the surface knows only the canvas size it rendered and its own
/// bounds. Everything the gestures need is derived here so the math has one
/// home and a unit test.
public enum PreviewFit {

    /// The centered, aspect-fitted rectangle of a `canvasSize` canvas inside
    /// `container` (same unit for both — points or pixels). Nil when either
    /// size is degenerate.
    public static func fittedRect(
        canvasSize: SIMD2<Double>, container: SIMD2<Double>
    ) -> CGRect? {
        guard canvasSize.x > 0, canvasSize.y > 0,
            container.x > 0, container.y > 0
        else { return nil }
        let scale = min(container.x / canvasSize.x, container.y / canvasSize.y)
        let shown = canvasSize * scale
        let origin = (container - shown) / 2
        return CGRect(x: origin.x, y: origin.y, width: shown.x, height: shown.y)
    }

    /// Fraction (0…1 on each axis, same orientation as `point`) of `point`
    /// within the fitted canvas rect; nil when the point falls in the
    /// letterbox/pillarbox area or the sizes are degenerate.
    public static func fraction(
        of point: CGPoint, canvasSize: SIMD2<Double>, container: CGSize
    ) -> CGPoint? {
        guard let rect = fittedRect(
            canvasSize: canvasSize,
            container: SIMD2(container.width, container.height))
        else { return nil }
        let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        guard local.x >= 0, local.y >= 0,
            local.x <= rect.width, local.y <= rect.height
        else { return nil }
        return CGPoint(x: local.x / rect.width, y: local.y / rect.height)
    }

    /// Transform that maps a canvas-space image (extent origin at 0,0 with
    /// size `canvasSize`) onto its aspect-fitted rect inside a drawable of
    /// `drawableSize` pixels. Fit is symmetric, so the same transform is
    /// correct in both top-left and bottom-left coordinate conventions.
    /// Identity when the sizes are degenerate.
    public static func transform(
        canvasSize: SIMD2<Double>, drawableSize: SIMD2<Double>
    ) -> CGAffineTransform {
        guard let rect = fittedRect(canvasSize: canvasSize, container: drawableSize)
        else { return .identity }
        let scale = rect.width / canvasSize.x
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
    }
}
