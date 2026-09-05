import AppKit
import AppSupport
import Observation
import SwiftUI

/// What the on-screen picker hands back, already in the coordinates the
/// capture pipeline consumes: display-local points, top-left origin
/// (`SourceGeometry.area`'s input).
struct AreaSelection: Equatable {
    let displayID: UInt32
    let rect: CGRect
}

/// Full-screen transparent overlay on every display: drag to draw a
/// selection, drag inside it to move, draw outside to start over; Return
/// or the strip's button confirms, Esc cancels. Built from non-activating
/// panels so a hotkey invocation from another app never yanks focus to
/// Screenreel's windows.
@MainActor
final class AreaPickerController {
    /// What the strip's primary button does: "Record" starts the countdown
    /// on confirm; "Use Area" only fills the start screen's fields.
    enum Intent {
        case record, useSelection

        var primaryTitle: String {
            switch self {
            case .record: return "Record"
            case .useSelection: return "Use Area"
            }
        }
    }

    private var panels: [AreaPickerPanel] = []
    private var completion: (@MainActor (AreaSelection?) -> Void)?

    var isPresenting: Bool { !panels.isEmpty }
    /// The overlay covering a display (self-test/diagnostics).
    func panel(forDisplayID displayID: UInt32) -> AreaPickerPanel? {
        panels.first { $0.displayID == displayID }
    }

    func present(
        intent: Intent, initial: AreaSelection? = nil,
        completion: @escaping @MainActor (AreaSelection?) -> Void
    ) {
        guard !isPresenting else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let panel = AreaPickerPanel(screen: screen, displayID: displayID, intent: intent)
            let screenHeight = screen.frame.height
            panel.pickerView.onSelectionBegan = { [weak self, weak panel] in
                self?.clearOthers(except: panel)
            }
            panel.pickerView.onCommit = { [weak self] rect in
                self?.finish(displayID: displayID, screenLocal: rect, screenHeight: screenHeight)
            }
            panel.pickerView.onCancel = { [weak self] in
                self?.cancel()
            }
            if let initial, initial.displayID == displayID {
                panel.pickerView.setSelection(
                    AreaGeometry.screenLocalBottomLeft(initial.rect, screenHeight: screenHeight))
            }
            panels.append(panel)
        }
        guard !panels.isEmpty else {
            self.completion = nil
            completion(nil)
            return
        }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        // Key panel: the one under the mouse, so Esc works immediately.
        let mouse = NSEvent.mouseLocation
        let under = panels.first { $0.frame.contains(mouse) } ?? panels[0]
        under.makeKeyAndOrderFront(nil)
        under.makeFirstResponder(under.pickerView)
    }

    func cancel() {
        finishAll(with: nil)
    }

    /// Return pressed anywhere (global interception): confirm whichever
    /// display holds the selection, if any.
    func commitCurrentSelection() {
        for panel in panels where panel.pickerView.selection != nil {
            panel.pickerView.commit()
            return
        }
    }

    private func finish(displayID: UInt32, screenLocal rect: CGRect, screenHeight: CGFloat) {
        let topLeft = AreaGeometry.displayLocalTopLeft(rect, screenHeight: screenHeight)
        finishAll(with: AreaSelection(displayID: displayID, rect: topLeft))
    }

    private func finishAll(with selection: AreaSelection?) {
        let done = completion
        completion = nil
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        done?(selection)
    }

    private func clearOthers(except panel: AreaPickerPanel?) {
        for other in panels where other !== panel {
            other.pickerView.clearSelection()
        }
    }
}

/// One overlay window, exactly covering one screen.
final class AreaPickerPanel: NSPanel {
    let displayID: UInt32
    let pickerView: AreaPickerView

    init(screen: NSScreen, displayID: UInt32, intent: AreaPickerController.Intent) {
        self.displayID = displayID
        pickerView = AreaPickerView(
            frame: NSRect(origin: .zero, size: screen.frame.size), intent: intent)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        contentView = pickerView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        // After isFloatingPanel: that setter rewrites the level to
        // .floating, which would leave the overlay under other panels.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The picker chrome must never land in a recording.
        sharingType = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Drawing + mouse/keyboard handling for one overlay. Coordinates are the
/// view's own (screen-local, bottom-left origin); the controller flips
/// them for the capture pipeline.
final class AreaPickerView: NSView {
    private enum Drag {
        case draw(anchor: CGPoint)
        case move(origin: CGRect, start: CGPoint)
    }

    private(set) var selection: CGRect?
    private var drag: Drag?
    private let intent: AreaPickerController.Intent
    private let strip: NSHostingView<AreaPickerStrip>

    var onSelectionBegan: (@MainActor () -> Void)?
    var onCommit: (@MainActor (CGRect) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    init(frame: NSRect, intent: AreaPickerController.Intent) {
        self.intent = intent
        strip = NSHostingView(rootView: AreaPickerStrip(
            sizeText: "", primaryTitle: intent.primaryTitle, onPrimary: {}, onCancel: {}))
        super.init(frame: frame)
        wantsLayer = true
        strip.isHidden = true
        addSubview(strip)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Selection state

    func setSelection(_ rect: CGRect) {
        selection = AreaGeometry.moved(AreaGeometry.snap(rect), by: .zero, within: bounds)
        drag = nil
        showStrip()
        needsDisplay = true
    }

    func clearSelection() {
        selection = nil
        drag = nil
        strip.isHidden = true
        needsDisplay = true
    }

    var isStripVisible: Bool { !strip.isHidden }
    var stripFrame: NSRect { strip.frame }

    func commit() {
        guard let selection else { return }
        onCommit?(selection)
    }

    private func showStrip() {
        guard let selection else { return }
        // A fresh root view with the final text, so the size measured
        // below is the size of what will be drawn (an observable text
        // change re-renders a turn later and measured the old content).
        strip.rootView = AreaPickerStrip(
            sizeText: AreaGeometry.sizeLabel(for: selection),
            primaryTitle: intent.primaryTitle,
            onPrimary: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.onCancel?() })
        strip.layoutSubtreeIfNeeded()
        let size = strip.fittingSize
        strip.frame = NSRect(
            origin: AreaGeometry.stripOrigin(for: selection, stripSize: size, within: bounds),
            size: size)
        strip.isHidden = false
    }

    // MARK: Cursor

    private func updateCursor(at point: CGPoint) {
        if case .move = drag {
            NSCursor.closedHand.set()
        } else if let selection, selection.contains(point), drag == nil,
            !(isStripVisible && strip.frame.contains(point))
        {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Esc must work on whichever display the mouse is over.
        window?.makeKey()
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeKey()
        window?.makeFirstResponder(self)
        strip.isHidden = true
        if let selection, selection.contains(point) {
            drag = .move(origin: selection, start: point)
        } else {
            selection = nil
            drag = .draw(anchor: point)
            onSelectionBegan?()
        }
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .draw(let anchor):
            selection = AreaGeometry.selection(from: anchor, to: point, within: bounds)
        case .move(let origin, let start):
            selection = AreaGeometry.moved(
                origin, by: CGSize(width: point.x - start.x, height: point.y - start.y),
                within: bounds)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        if selection != nil {
            showStrip()
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            onCancel?()
        case 36, 76:  // Return, keypad Enter
            commit()
        default:
            break  // swallow: a beep per stray key would be noise
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.42)
        if let selection {
            let mask = NSBezierPath(rect: bounds)
            mask.appendRect(selection)
            mask.windingRule = .evenOdd
            dim.setFill()
            mask.fill()

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            border.stroke()

            if strip.isHidden {
                drawLabel(AreaGeometry.sizeLabel(for: selection), near: selection)
            }
        } else {
            dim.setFill()
            bounds.fill()
            drawHint()
        }
    }

    private func drawLabel(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let pad = CGSize(width: 8, height: 4)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + textSize.height + pad.height * 2 > bounds.maxY {
            origin.y = rect.maxY - textSize.height - pad.height * 2 - 6
        }
        let box = CGRect(
            x: origin.x, y: origin.y,
            width: textSize.width + pad.width * 2, height: textSize.height + pad.height * 2)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }

    private func drawHint() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(
            string: "Drag to select an area to record  ·  esc to cancel", attributes: attributes)
        let textSize = string.size()
        let pad = CGSize(width: 16, height: 9)
        let box = CGRect(
            x: (bounds.midX - textSize.width / 2 - pad.width).rounded(),
            y: (bounds.midY - textSize.height / 2 - pad.height).rounded(),
            width: textSize.width + pad.width * 2, height: textSize.height + pad.height * 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        string.draw(at: CGPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }
}

/// The Record/Cancel strip under a finished selection.
struct AreaPickerStrip: View {
    let sizeText: String
    let primaryTitle: String
    let onPrimary: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(sizeText)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            Divider()
                .frame(height: 16)
                .overlay(.white.opacity(0.2))
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
            Button {
                onPrimary()
            } label: {
                Label(primaryTitle, systemImage: "record.circle.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Text("↩")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.14)))
        .preferredColorScheme(.dark)
    }
}
