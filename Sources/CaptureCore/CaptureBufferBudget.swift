/// Bounds for live video surfaces. Keep the compositor and handoff in sync:
/// queued samples retain ScreenCaptureKit's IOSurfaces until encoding ends.
public enum CaptureBufferBudget {
    public static let screenSurfaces = 5
    public static let pendingScreenFrames = 2
    public static let pendingCameraFrames = 3
}
