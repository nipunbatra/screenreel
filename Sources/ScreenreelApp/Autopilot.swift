import AppKit
import Foundation
import ProjectModel

/// Env-gated self-driving smoke harness: when `SCREENREEL_AUTOPILOT_DIR` is set, the
/// app walks its own primary flow — start view → open project → play →
/// restyle → export — through the exact code paths the buttons invoke,
/// snapshotting its window to PNG at each step (self-rendering needs no
/// Screen Recording permission) and writing a machine-readable report.
///
/// This is a verification harness, not a user feature: it only ever runs
/// when the environment variable is present.
extension AppModel {

    func startAutopilotIfRequested() {
        guard let directoryPath = ProcessInfo.processInfo.environment["SCREENREEL_AUTOPILOT_DIR"],
            !autopilotStarted
        else { return }
        autopilotStarted = true
        let directory = URL(fileURLWithPath: directoryPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await self.runAutopilot(reportingTo: directory)
        }
    }

    private func runAutopilot(reportingTo directory: URL) async {
        var report: [String: String] = [:]
        func snapshot(_ name: String) {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                report[name] = "snapshot-failed"
                return
            }
            // Resolve dynamic colors against the window's real appearance,
            // or dark-mode text caches as white-on-white.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            // cacheDisplay renders view drawing, not CAMetalLayer contents:
            // the editor's preview surface comes out as its backdrop. Paint
            // the frame it last presented into its rect so the PNG shows
            // what the user sees (a readback the interactive path never does).
            var editorPlayer: PreviewPlayer?
            if case .editor(let player) = mode { editorPlayer = player }
            let composited = Self.overlayPreviewFrame(
                on: bitmap, contentView: view, player: editorPlayer) ?? bitmap
            if let png = composited.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
                report[name] = "ok"
            } else {
                report[name] = "png-encode-failed"
            }
            // Ground truth beside it: the window as WindowServer composites
            // it (Metal layer included). An app may capture its own windows
            // without the Screen Recording grant; if the capture comes back
            // empty this file is simply absent.
            if let windowImage = Self.captureOwnWindow(window), windowImage.width > 1 {
                let rep = NSBitmapImageRep(cgImage: windowImage)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name)-window.png"))
                    report["\(name)-window"] = "\(windowImage.width)x\(windowImage.height)"
                }
            }
        }
        func finish() {
            let ordered = report.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            try? Data((ordered + "\n").utf8).write(
                to: directory.appendingPathComponent("report.txt"))
        }
        // Stage markers, appended as the run proceeds: a run that never
        // writes its report can still be localized to the stage it reached.
        func mark(_ stage: String) {
            let line = "\(Date().timeIntervalSince1970) \(stage)\n"
            let url = directory.appendingPathComponent("progress.txt")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }

        try? await Task.sleep(for: .seconds(2))
        snapshot("1-start")
        report["recents"] = "\(recentProjects.count)"

        // Real-capture mode (SCREENREEL_AUTOPILOT_RECORD=seconds): drive an actual
        // ScreenCaptureKit recording through the same paths the Record
        // button uses, verifying the window choreography the floating-pill
        // fix promises — main window hidden, small floating panel shown —
        // then stop, land in the editor, and validate the project.
        if let secondsText = ProcessInfo.processInfo.environment["SCREENREEL_AUTOPILOT_RECORD"],
            let seconds = Int(secondsText), seconds > 0
        {
            // NOTE: runRecordFlow returns its results instead of taking
            // `report` inout — `snapshot` captures `report`, and passing the
            // same variable inout while a passed closure mutates it is a
            // Swift exclusivity violation that traps at runtime.
            let recordReport = await runRecordFlow(seconds: seconds, snapshot: snapshot)
            report.merge(recordReport) { _, new in new }
            finish()
            return
        }

        // Open the project under test (explicit path, else newest recent).
        let projectURL = ProcessInfo.processInfo.environment["SCREENREEL_AUTOPILOT_PROJECT"]
            .map { URL(fileURLWithPath: $0) } ?? recentProjects.first
        guard let projectURL else {
            report["result"] = "no-project-available"
            finish()
            return
        }
        // The harness restyles and exports the project it opens. Work on a
        // throwaway copy under the report directory so the user's real
        // recording never picks up the harness's orange gradient (it used
        // to) — SCREENREEL_AUTOPILOT_IN_PLACE=1 keeps the old behavior.
        var workingURL = projectURL
        if ProcessInfo.processInfo.environment["SCREENREEL_AUTOPILOT_IN_PLACE"] != "1" {
            let copyURL = directory.appendingPathComponent(projectURL.lastPathComponent)
            try? FileManager.default.removeItem(at: copyURL)
            do {
                try FileManager.default.copyItem(at: projectURL, to: copyURL)
                workingURL = copyURL
            } catch {
                // Never fall back to the user's real project.
                report["result"] = "project-copy-failed: \(error.localizedDescription)"
                finish()
                return
            }
        }
        report["project"] = workingURL.path
        openProject(at: workingURL)
        try? await Task.sleep(for: .seconds(3))
        guard case .editor(let player) = mode else {
            report["result"] = "editor-did-not-open: \(statusMessage ?? "unknown")"
            finish()
            return
        }
        report["durationNs"] = "\(player.durationNs)"
        report["zooms"] = "\(player.edits.zooms.count)"
        snapshot("2-editor")

        // Play for a moment; the playhead and frame must advance.
        // SCREENREEL_AUTOPILOT_PLAY_SECONDS lengthens this for performance
        // sampling (CPU/GPU while the preview runs at the real window size).
        let playSeconds = ProcessInfo.processInfo.environment["SCREENREEL_AUTOPILOT_PLAY_SECONDS"]
            .flatMap(Double.init) ?? 2
        mark("play-start")
        player.play()
        // Progress while playing, so a stall mid-playback is visible.
        let playDeadline = Date().addingTimeInterval(playSeconds)
        var tick = 0
        while Date() < playDeadline {
            try? await Task.sleep(for: .seconds(1))
            tick += 1
            mark("playing t=\(player.timeNs / 1_000_000) ms frames=\(player.renderedFrameCount)")
            // Two live-window captures a second apart: the preview area
            // must differ between them if presented drawables reach the
            // screen. Plus the surface/sink wiring at that moment.
            if tick == 3 || tick == 4 {
                if let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                    let image = Self.captureOwnWindow(window),
                    let png = NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:])
                {
                    try? png.write(to: directory.appendingPathComponent("play-\(tick)-window.png"))
                }
                if tick == 3,
                    let content = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView
                {
                    let surfaces = MetalPreviewNSView.findAll(in: content)
                    report["surfaces"] = "\(surfaces.count)"
                    for (index, surface) in surfaces.enumerated() {
                        report["surface\(index)"] =
                            "sink=\(player.isFrameSink(surface)) " + surface.diagnostics
                    }
                }
            }
        }
        report["framesRendered"] = "\(player.renderedFrameCount)"
        mark("play-end")
        player.pause()
        report["playheadNs"] = "\(player.timeNs)"
        report["playbackAdvanced"] = player.timeNs > 500_000_000 ? "yes" : "NO"
        mark("snapshot-3-start")
        snapshot("3-played")
        mark("snapshot-3-done")

        // Direct manipulation through the real event path: a synthesized
        // click delivered by the window must reach the Metal surface's
        // mouse handling and re-aim the selected zoom.
        report["tapAim"] = await verifyTapToAim(player: player)
        mark("tap-done")

        // Restyle through the same mutation path the inspector uses.
        player.updateEdits { edits in
            edits.style.background = .linearGradient(
                top: .init(red: 0.85, green: 0.42, blue: 0.25),
                bottom: .init(red: 0.35, green: 0.12, blue: 0.35))
            edits.style.padding = 0.1
            edits.style.cornerRadius = 0.05
        }
        try? await Task.sleep(for: .seconds(2))
        snapshot("4-restyled")

        // Styled export through the player's export path (no save panel).
        let exportURL = directory.appendingPathComponent("autopilot-export.mp4")
        player.export(to: exportURL, styled: true, height: nil)
        let deadline = Date().addingTimeInterval(180)
        exportLoop: while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            switch player.exportState {
            case .done(let url):
                report["export"] = "done \(url.lastPathComponent)"
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
                report["exportBytes"] = size.map(String.init) ?? "?"
                break exportLoop
            case .failed(let message):
                report["export"] = "FAILED \(message)"
                break exportLoop
            case .idle, .running:
                continue
            }
        }
        if report["export"] == nil {
            report["export"] = "TIMEOUT"
        }
        snapshot("5-exported")

        report["result"] = report["export"]?.hasPrefix("done") == true
            && report["playbackAdvanced"] == "yes" ? "PASS" : "FAIL"
        finish()
    }

    /// WindowServer's composite of one of our own windows, Metal layer and
    /// all. `CGWindowListCreateImage` is marked unavailable to Swift on
    /// macOS 15 (ScreenCaptureKit is the replacement, but it needs the
    /// Screen Recording grant even for our own windows, which an ad-hoc
    /// signed harness build never holds); the symbol is still exported, so
    /// the harness looks it up at runtime. Nil when it is gone.
    private static func captureOwnWindow(_ window: NSWindow) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect, UInt32, UInt32, UInt32
        ) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3;
        // kCGWindowImageBoundsIgnoreFraming = 1 << 0, kCGWindowImageBestResolution = 1 << 3.
        return capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?
            .takeRetainedValue()
    }

    /// Composite the preview surface's pixels (the last frame, rendered
    /// through the surface's own encode path into an offscreen texture of
    /// the drawable's size, rounded corners included) over a window
    /// snapshot at the surface's rect. Nil when there is no editor,
    /// surface, or frame yet — the caller then keeps the plain snapshot.
    private static func overlayPreviewFrame(
        on bitmap: NSBitmapImageRep, contentView: NSView, player: PreviewPlayer?
    ) -> NSBitmapImageRep? {
        guard let player,
            let surface = MetalPreviewNSView.find(in: contentView),
            let frame = player.snapshotFrame(),
            let base = bitmap.cgImage
        else { return nil }
        // Window base coordinates are bottom-left, like the CG bitmap.
        let surfaceRect = surface.convert(surface.bounds, to: nil)
        let contentRect = contentView.convert(contentView.bounds, to: nil)
        let scale = CGFloat(bitmap.pixelsWide) / max(1, contentView.bounds.width)
        let target = CGRect(
            x: (surfaceRect.minX - contentRect.minX) * scale,
            y: (surfaceRect.minY - contentRect.minY) * scale,
            width: surfaceRect.width * scale,
            height: surfaceRect.height * scale)
        guard let context = CGContext(
            data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(
            base,
            in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.saveGState()
        let radius = MetalPreviewNSView.cornerRadius * scale
        context.addPath(CGPath(
            roundedRect: target, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(frame, in: target)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Click the preview surface through `NSWindow.sendEvent` and report
    /// whether the selected zoom's focal moved: "yes …", "NO …", or
    /// "skipped-…" when the project has no zoom to aim.
    private func verifyTapToAim(player: PreviewPlayer) async -> String {
        guard let zoom = player.edits.zooms.first else { return "skipped-no-zoom" }
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
            let content = window.contentView,
            let surface = MetalPreviewNSView.find(in: content),
            surface.bounds.width > 10, surface.bounds.height > 10
        else { return "skipped-no-surface" }
        player.selectedZoomID = zoom.id
        // Off-centre so the new focal cannot coincide with the old one
        // (view coordinates here are AppKit's bottom-left origin).
        let local = CGPoint(x: surface.bounds.width * 0.8, y: surface.bounds.height * 0.7)
        let point = surface.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            return "skipped-no-event"
        }
        // Diagnostics: which view the window resolves at that point, and
        // whether the surface's own mouseDown ran.
        let hitView = content.superview?.hitTest(point) ?? content.hitTest(point)
        let hitName = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        let pressesBefore = surface.mouseDownCount
        window.sendEvent(down)
        try? await Task.sleep(for: .milliseconds(80))
        window.sendEvent(up)
        try? await Task.sleep(for: .seconds(1))
        let diagnostics =
            "hit=\(hitName) presses=\(surface.mouseDownCount - pressesBefore)"
            + " rendered=\(player.hasRenderedFrame)"
            + " canvas=\(player.latestFrame.map { "\(Int($0.canvasSize.x))x\(Int($0.canvasSize.y))" } ?? "none")"
            + " surface=\(Int(surface.bounds.width))x\(Int(surface.bounds.height))"
        guard let after = player.edits.zooms.first(where: { $0.id == zoom.id }) else {
            return "NO zoom-vanished \(diagnostics)"
        }
        let moved = abs(after.focalX - zoom.focalX) > 0.004
            || abs(after.focalY - zoom.focalY) > 0.004
        return String(
            format: "%@ focal %.3f,%.3f -> %.3f,%.3f %@",
            moved ? "yes" : "NO", zoom.focalX, zoom.focalY, after.focalX, after.focalY,
            diagnostics)
    }

    private func runRecordFlow(
        seconds: Int,
        snapshot: (String) -> Void
    ) async -> [String: String] {
        var report: [String: String] = [:]
        // Display enumeration can lag on a loaded machine: give it up to
        // 12 s before declaring a permission problem.
        for _ in 0..<24 where displays.isEmpty {
            refreshDisplays()
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !displays.isEmpty else {
            report["result"] = "FAIL no-screen-permission (after 12 s retry)"
            report["preflight"] = "\(CGPreflightScreenCaptureAccess())"
            return report
        }
        startCountdown()
        // 3 s countdown + capture spin-up.
        try? await Task.sleep(for: .seconds(5))
        guard case .recording = mode else {
            report["result"] = "FAIL recording-did-not-start: \(statusMessage ?? "?")"
            return report
        }

        // The fix under test: the app must get OUT of the way. Titled
        // windows only — the menu-bar status item owns a borderless
        // NSWindow that is legitimately visible.
        let mainVisible = NSApplication.shared.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        report["mainWindowHiddenWhileRecording"] = mainVisible ? "NO" : "yes"
        report["hudPanelVisible"] = hudPanel.isVisible ? "yes" : "NO"
        report["hudPanelFloating"] =
            (hudPanel.panelLevel == .floating) ? "yes" : "NO"

        try? await Task.sleep(for: .seconds(seconds))
        report["recordingElapsed"] = elapsedText
        stopRecording()

        // Stop finalizes segments, then opens the editor.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if case .editor = mode { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard case .editor(let player) = mode else {
            report["result"] = "FAIL editor-did-not-open-after-stop: \(statusMessage ?? "?")"
            return report
        }
        report["mainWindowRestored"] = NSApplication.shared.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        } ? "yes" : "NO"
        // PreviewPlayer loads duration asynchronously; give it a moment.
        try? await Task.sleep(for: .seconds(2))
        report["recordedDurationNs"] = "\(player.durationNs)"
        snapshot("record-editor")

        let expectedNs = Int64(seconds) * 1_000_000_000
        let durationOK = player.durationNs > expectedNs / 2
        report["result"] =
            (report["mainWindowHiddenWhileRecording"] == "yes"
                && report["hudPanelVisible"] == "yes"
                && report["hudPanelFloating"] == "yes"
                && report["mainWindowRestored"] == "yes"
                && durationOK) ? "PASS" : "FAIL"
        report["recordedProject"] = player.projectURL.path
        return report
    }
}
