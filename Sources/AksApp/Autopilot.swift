import AppKit
import Foundation
import ProjectModel

/// Env-gated self-driving smoke harness: when `AKS_AUTOPILOT_DIR` is set, the
/// app walks its own primary flow — start view → open project → play →
/// restyle → export — through the exact code paths the buttons invoke,
/// snapshotting its window to PNG at each step (self-rendering needs no
/// Screen Recording permission) and writing a machine-readable report.
///
/// This is a verification harness, not a user feature: it only ever runs
/// when the environment variable is present.
extension AppModel {

    func startAutopilotIfRequested() {
        guard let directoryPath = ProcessInfo.processInfo.environment["AKS_AUTOPILOT_DIR"],
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
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
                report[name] = "ok"
            } else {
                report[name] = "png-encode-failed"
            }
        }
        func finish() {
            let ordered = report.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            try? Data((ordered + "\n").utf8).write(
                to: directory.appendingPathComponent("report.txt"))
        }

        try? await Task.sleep(for: .seconds(2))
        snapshot("1-start")
        report["recents"] = "\(recentProjects.count)"

        // Real-capture mode (AKS_AUTOPILOT_RECORD=seconds): drive an actual
        // ScreenCaptureKit recording through the same paths the Record
        // button uses, verifying the window choreography the floating-pill
        // fix promises — main window hidden, small floating panel shown —
        // then stop, land in the editor, and validate the project.
        if let secondsText = ProcessInfo.processInfo.environment["AKS_AUTOPILOT_RECORD"],
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
        let projectURL = ProcessInfo.processInfo.environment["AKS_AUTOPILOT_PROJECT"]
            .map { URL(fileURLWithPath: $0) } ?? recentProjects.first
        guard let projectURL else {
            report["result"] = "no-project-available"
            finish()
            return
        }
        // The harness restyles and exports the project it opens. Work on a
        // throwaway copy under the report directory so the user's real
        // recording never picks up the harness's orange gradient (it used
        // to) — AKS_AUTOPILOT_IN_PLACE=1 keeps the old behavior.
        var workingURL = projectURL
        if ProcessInfo.processInfo.environment["AKS_AUTOPILOT_IN_PLACE"] != "1" {
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
        // AKS_AUTOPILOT_PLAY_SECONDS lengthens this for performance
        // sampling (CPU/GPU while the preview runs at the real window size).
        let playSeconds = ProcessInfo.processInfo.environment["AKS_AUTOPILOT_PLAY_SECONDS"]
            .flatMap(Double.init) ?? 2
        player.play()
        try? await Task.sleep(for: .seconds(playSeconds))
        report["framesRendered"] = "\(player.renderedFrameCount)"
        player.pause()
        report["playheadNs"] = "\(player.timeNs)"
        report["playbackAdvanced"] = player.timeNs > 500_000_000 ? "yes" : "NO"
        snapshot("3-played")

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
