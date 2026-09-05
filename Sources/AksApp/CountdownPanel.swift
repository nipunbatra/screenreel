import AppKit
import Observation
import SwiftUI

extension NSScreen {
    /// The CGDirectDisplayID behind this screen (what ScreenCaptureKit and
    /// CoreGraphics call the display).
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(forDisplayID displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return screens.first { $0.displayID == displayID }
    }
}

/// The on-screen countdown: a non-activating panel centered on the display
/// about to be recorded. Used for EVERY countdown, so a hotkey start with
/// the main window hidden still shows a visible "3 · 2 · 1" with a way out
/// (Esc) and a way to skip ahead (click, Return, or Space).
@MainActor
final class CountdownPanelController {
    @Observable
    final class State {
        var remaining: Int
        init(remaining: Int) { self.remaining = remaining }
    }

    private var panel: CountdownPanel?
    private var state: State?

    var isVisible: Bool { panel?.isVisible ?? false }
    var panelLevel: NSWindow.Level? { panel?.level }
    var remaining: Int? { state?.remaining }

    func show(
        remaining: Int, onDisplayID displayID: UInt32?,
        onStartNow: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        hide()
        let state = State(remaining: remaining)
        let size = NSSize(width: 280, height: 280)
        let content = NSHostingView(
            rootView: CountdownPanelView(state: state).preferredColorScheme(.dark))
        content.frame = NSRect(origin: .zero, size: size)

        let panel = CountdownPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = content
        panel.onStartNow = onStartNow
        panel.onCancel = onCancel
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Never in its own recording, even if a frame slips in before hide.
        panel.sharingType = .none

        let screen = NSScreen.screen(forDisplayID: displayID) ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrameOrigin(NSPoint(
                x: (frame.midX - size.width / 2).rounded(),
                y: (frame.midY - size.height / 2).rounded()))
        }
        // Key without activating the app: Esc/Return reach the panel while
        // whatever the user was working in stays frontmost.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.state = state
    }

    func update(remaining: Int) {
        guard let state else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            state.remaining = remaining
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }
}

/// Borderless panel that can become key so Esc/Return work, and that
/// treats any click or Return as "start now".
final class CountdownPanel: NSPanel {
    var onStartNow: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            switch event.keyCode {
            case 53:  // Esc
                onCancel?()
                return
            case 36, 76, 49:  // Return, keypad Enter, Space
                onStartNow?()
                return
            default:
                break
            }
        case .leftMouseDown:
            onStartNow?()
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

struct CountdownPanelView: View {
    let state: CountdownPanelController.State

    var body: some View {
        VStack(spacing: 8) {
            Text("\(state.remaining)")
                .font(.system(size: 132, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .foregroundStyle(.red)
            Text("Click to start now")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Text("esc to cancel")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: 280, height: 280)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.white.opacity(0.12)))
    }
}
