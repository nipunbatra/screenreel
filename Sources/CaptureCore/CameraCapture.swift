@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ProjectModel
import Synchronization

/// Webcam capture as a `ScreenFrameSource`: AVCaptureSession → BGRA frames
/// with session-normalized timestamps, feeding the same segmented video
/// writer pipeline the screen uses. The raw camera track lands under
/// `raw/camera/` per the project format.
public final class CameraCapture: NSObject, ScreenFrameSource, @unchecked Sendable {

    public struct CameraInfo: Sendable, Identifiable {
        public var id: String { uniqueID }
        public let uniqueID: String
        public let name: String
    }

    public static func availableCameras() -> [CameraInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices.map {
            CameraInfo(uniqueID: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Output dimensions for a device (its active format), even-rounded.
    public static func dimensions(forDeviceID deviceID: String?) -> (width: Int, height: Int) {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return (1280, 720) }
        let description = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return (Int(dimensions.width) / 2 * 2, Int(dimensions.height) / 2 * 2)
    }

    private let clock: SessionClock
    private let deviceID: String?
    private let session = AVCaptureSession()

    /// The live session, for attaching an AVCaptureVideoPreviewLayer
    /// (self-view in the recording pill). Preview layers are passive
    /// consumers; they never touch the recorded frames.
    public var captureSession: AVCaptureSession { session }
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "screenreel.camera", qos: .userInitiated)
    private let handler = Mutex<(@Sendable (VideoFrame) -> Void)?>(nil)

    public init(clock: SessionClock, deviceID: String?) {
        self.clock = clock
        self.deviceID = deviceID
    }

    public func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        try await Self.requirePermission(status: AVCaptureDevice.authorizationStatus(for: .video)) {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        self.handler.withLock { $0 = handler }

        let device = deviceID.map { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            throw ScreenreelError.invariantViolated("no camera available")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw ScreenreelError.invariantViolated("camera input rejected (permission denied?)")
        }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw ScreenreelError.invariantViolated("camera output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else {
            self.handler.withLock { $0 = nil }
            throw NSError(domain: "ScreenReel.Camera", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The camera could not start. Check that it is connected and available, then try again."
            ])
        }
    }

    /// Shared by app and CLI; device construction alone does not request access.
    static func requirePermission(status: AVAuthorizationStatus, request: () async -> Bool) async throws {
        if status == .authorized { return }
        if status == .notDetermined, await request() { return }
        throw NSError(domain: "ScreenReel.Camera", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Camera access is required. Allow Camera access for Screen Reel (or the terminal running screenreel) in System Settings → Privacy & Security → Camera, then record again."
        ])
    }

    public func stop() async {
        session.stopRunning()
        handler.withLock { $0 = nil }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let handler = self.handler.withLock { $0 }
        guard let handler,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        let hostNs = Int64(pts.seconds * 1_000_000_000)
        handler(VideoFrame(
            pixelBuffer: pixelBuffer,
            ptsNs: clock.normalizeHostNs(hostNs),
            sourceNs: hostNs))
    }
}
