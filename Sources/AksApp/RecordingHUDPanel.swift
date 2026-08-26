import AppKit
import AVFoundation
import SwiftUI

/// The floating recording pill: a small
/// NON-ACTIVATING panel that stays above other windows WITHOUT keeping the
/// whole app window on top — the previous approach floated the entire main
/// window, which sat over everything the user was trying to record and
/// could not be sent behind.
@MainActor
final class RecordingHUDPanelController {
    private var panel: NSPanel?

    func show(model: AppModel, onDisplayID displayID: UInt32?) {
        hide()
        let content = NSHostingView(
            rootView: CompactRecordingHUD()
                .environment(model)
                .preferredColorScheme(.dark))
        content.setFrameSize(content.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The pill must never appear in its own recording.
        panel.sharingType = .none

        // Top-right of the recorded display, clear of the menu bar.
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
                == displayID
        } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = content.fittingSize
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 24,
                y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var panelLevel: NSWindow.Level? { panel?.level }
}

/// The pill itself: status dot, elapsed time, pause/stop — plus a live
/// camera self-view when the webcam is recording, so you know your
/// framing the whole time.
private struct CompactRecordingHUD: View {
    @Environment(AppModel.self) private var model
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            if let session = model.activeCameraSession {
                CameraPreviewView(session: session)
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.white.opacity(0.15)))
            }
            Circle()
                .fill(model.isPaused ? Color.orange : .red)
                .frame(width: 9, height: 9)
            Text(model.elapsedText)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .id(tick)
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.footnote.bold())
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.12), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(model.isPaused ? "Resume" : "Pause")
            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.footnote.bold())
                    .frame(width: 26, height: 26)
                    .background(.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(6)
        .onReceive(timer) { now in tick = now }
    }
}

/// Live AVCaptureSession preview (used by the pill's self-view and the
/// start screen's camera preview).
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewNSView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView(frame: .zero)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Selfie views read naturally mirrored.
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        view.layer = layer
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        if let layer = view.layer as? AVCaptureVideoPreviewLayer, layer.session !== session {
            layer.session = session
        }
    }
}
