import Foundation

/// How large a recorded cursor sprite should appear, in SOURCE pixels.
///
/// Descriptors record the sprite's own pixel size plus its backing scale
/// (NSCursor images can be rendered at many times their point size —
/// a 17×23 pt arrow arrives as a 170×230 px sprite with backingScale 10).
/// Drawing sprite pixels 1:1 as source pixels produced a comically giant
/// cursor; the on-screen size is points × the capture's pixels-per-point.
public enum CursorSpriteMath {
    public static func sourceSize(
        spriteWidthPx: Double, spriteHeightPx: Double,
        backingScale: Double, captureScale: Double
    ) -> SIMD2<Double> {
        // Defensive: a missing/garbage backing scale falls back to
        // treating sprite pixels as already-source pixels.
        guard backingScale > 0.01 else {
            return SIMD2(spriteWidthPx, spriteHeightPx)
        }
        let scale = captureScale > 0.01 ? captureScale : 2
        return SIMD2(
            spriteWidthPx / backingScale * scale,
            spriteHeightPx / backingScale * scale)
    }
}
