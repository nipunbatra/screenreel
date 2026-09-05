import AppKit
import AppSupport
import CaptureCore
import Foundation
import ProjectModel

/// Env-gated self-test for the frictionless-start surfaces that need no
/// Screen Recording permission: when `AKS_UX_SELFTEST_DIR` is set, the app
/// drives its own menu bar item, global hotkey registration, countdown
/// panel, and area-picker overlay through synthesized events, snapshots
/// the overlay to PNG, writes a machine-readable report, and quits.
///
/// A verification harness, not a user feature. It touches the user's
/// screen for about two seconds (overlay + countdown panel) and never
/// writes preferences.
extension AppModel {

    func startUXSelfTestIfRequested() {
        guard let directoryPath = ProcessInfo.processInfo.environment["AKS_UX_SELFTEST_DIR"],
            !uxSelfTestStarted
        else { return }
        uxSelfTestStarted = true
        let directory = URL(fileURLWithPath: directoryPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await self.runUXSelfTest(reportingTo: directory)
        }
    }

    private func runUXSelfTest(reportingTo directory: URL) async {
        var report: [String: String] = [:]
        var failures: [String] = []
        // Flushed after every check so a crash mid-run still leaves a
        // partial report pointing at the last step that ran.
        func flush() {
            let ordered = report.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            try? Data((ordered + "\n").utf8).write(
                to: directory.appendingPathComponent("report.txt"))
        }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            report[name] = ok ? "yes" : "NO" + (detail.isEmpty ? "" : " (\(detail))")
            if !ok { failures.append(name) }
            flush()
        }
        func finish() {
            report["result"] = failures.isEmpty ? "PASS" : "FAIL \(failures.joined(separator: ","))"
            flush()
        }
        report["started"] = RFC3339.now()
        flush()
        func snapshot(_ view: NSView, _ name: String) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                report["snapshot.\(name)"] = "failed"
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
                report["snapshot.\(name)"] = "ok"
            }
        }

        try? await Task.sleep(for: .seconds(1.5))

        // MARK: Preferences + folder
        report["prefs.countdown"] = "\(preferences.countdownSeconds)"
        report["prefs.showInMenuBar"] = "\(preferences.showInMenuBar)"
        report["prefs.folder"] = recordingsDirectoryDisplayPath
        check("folder.exists", FileManager.default.fileExists(atPath: recordingsDirectory.path))

        // MARK: Menu bar
        check("menu.inserted", menuBar.isInserted || !preferences.showInMenuBar)
        let idleTitles = menuBar.currentMenuTitles()
        report["menu.idle"] = idleTitles.joined(separator: " / ")
        check("menu.idle.hasRecordScreen", idleTitles.first == MenuBarController.recordTitle(for: self))
        check("menu.idle.hasRecordWindow", idleTitles.contains("Record Window…"))
        check("menu.idle.hasRecordArea", idleTitles.contains("Record Area…"))
        check("menu.idle.hasRecent", idleTitles.contains { $0.hasPrefix("Recent > ") })
        check("menu.idle.hasSettings", idleTitles.contains("Settings…"))
        check("menu.idle.hasQuit", idleTitles.contains("Quit \(Branding.displayName)"))
        check("menu.idle.recentCapped",
            (idleTitles.first { $0.hasPrefix("Recent > ") }?
                .components(separatedBy: " | ").count ?? 0) <= 5)
        check("menu.icon.template", menuBar.statusSymbolIsTemplate ?? true)
        check("menu.icon.noElapsedWhileIdle", menuBar.statusButtonTitle.isEmpty)

        // MARK: Hotkeys
        let registered = HotkeyCenter.shared.registeredActions
        let expected = Set(HotkeyAction.allCases.filter { preferences.hotkey(for: $0) != .off })
        report["hotkeys.registered"] = registered.map { "\($0)" }.sorted().joined(separator: ",")
        report["hotkeys.failures"] = HotkeyCenter.shared.failures
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        check("hotkeys.allRegistered", registered == expected, "expected \(expected.count)")
        // Chord glyphs the menu and Settings show for the defaults.
        report["hotkeys.labels"] = HotkeyAction.allCases
            .map { "\($0)=\(preferences.hotkey(for: $0).label)" }.joined(separator: ",")

        // MARK: Countdown panel
        var cancelled = false
        var started = false
        countdownPanel.show(
            remaining: 3, onDisplayID: NSScreen.main?.displayID,
            onStartNow: { started = true },
            onCancel: { cancelled = true })
        // Key status is checked synchronously: other apps activating in the
        // background (there are concurrent harness runs on this machine)
        // legitimately take it away later, and that is not a defect.
        // Key status is informational: a process launched from a shell by
        // a non-user parent is never granted activation on macOS 14+, so
        // nothing in it can be key here. Esc/Return are therefore also
        // intercepted through Carbon while an overlay is up (checked below).
        report["app.isActive"] = "\(NSApplication.shared.isActive)"
        report["countdown.isKey"] = "\(countdownPanel.panel?.isKeyWindow ?? false) (informational)"
        check("countdown.canBecomeKey", countdownPanel.panel?.canBecomeKey == true)
        try? await Task.sleep(for: .milliseconds(300))
        check("countdown.visible", countdownPanel.isVisible)
        check("countdown.aboveEverything", countdownPanel.panelLevel == .screenSaver)
        if let panel = countdownPanel.panel, let screen = NSScreen.main {
            let centered = abs(panel.frame.midX - screen.frame.midX) < 2
                && abs(panel.frame.midY - screen.frame.midY) < 2
            check("countdown.centeredOnDisplay", centered, "\(panel.frame) in \(screen.frame)")
            check("countdown.excludedFromCapture", panel.sharingType == .none)
            if let content = panel.contentView { snapshot(content, "countdown") }
        }
        countdownPanel.update(remaining: 2)
        check("countdown.updates", countdownPanel.remaining == 2)
        if let panel = countdownPanel.panel,
            let esc = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)
        {
            panel.sendEvent(esc)
        }
        check("countdown.escCancels", cancelled && !started)
        countdownPanel.hide()
        check("countdown.hidden", !countdownPanel.isVisible)
        _ = started

        // MARK: Area picker
        var result: AreaSelection?
        var completed = false
        areaPicker.present(intent: .record, initial: nil) { selection in
            result = selection
            completed = true
        }
        let somePanelIsKey = NSScreen.screens.contains { screen in
            screen.displayID.flatMap { areaPicker.panel(forDisplayID: $0) }?.isKeyWindow == true
        }
        report["picker.somePanelIsKey"] = "\(somePanelIsKey) (informational)"
        try? await Task.sleep(for: .milliseconds(300))
        check("picker.presenting", areaPicker.isPresenting)
        check("picker.onePanelPerScreen",
            NSScreen.screens.allSatisfy { screen in
                screen.displayID.flatMap { areaPicker.panel(forDisplayID: $0) } != nil
            })
        guard let screen = NSScreen.main, let displayID = screen.displayID,
            let panel = areaPicker.panel(forDisplayID: displayID)
        else {
            check("picker.mainPanel", false)
            areaPicker.cancel()
            finish()
            NSApplication.shared.terminate(nil)
            return
        }
        let view = panel.pickerView
        check("picker.coversScreen", panel.frame == screen.frame, "\(panel.frame) vs \(screen.frame)")
        check("picker.aboveEverything", panel.level == .screenSaver)
        check("picker.excludedFromCapture", panel.sharingType == .none)
        check("picker.acceptsFirstMouse", view.acceptsFirstMouse(for: nil))
        snapshot(view, "picker-empty")

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Draw from bottom-right to top-left (reversed drag) — the view's
        // coordinates are bottom-left, so this is the rect
        // x 300..940, y 200..560 in screen-local points.
        if let down = mouse(.leftMouseDown, CGPoint(x: 940, y: 200)),
            let drag1 = mouse(.leftMouseDragged, CGPoint(x: 600, y: 400)),
            let drag2 = mouse(.leftMouseDragged, CGPoint(x: 300, y: 560)),
            let up = mouse(.leftMouseUp, CGPoint(x: 300, y: 560))
        {
            view.mouseDown(with: down)
            view.mouseDragged(with: drag1)
            check("picker.liveSelectionDuringDrag",
                view.selection == CGRect(x: 600, y: 200, width: 340, height: 200),
                "\(String(describing: view.selection))")
            check("picker.stripHiddenDuringDrag", !view.isStripVisible)
            view.mouseDragged(with: drag2)
            view.mouseUp(with: up)
        }
        let drawn = CGRect(x: 300, y: 200, width: 640, height: 360)
        check("picker.selectionAfterDrag", view.selection == drawn, "\(String(describing: view.selection))")
        check("picker.stripShownAfterMouseUp", view.isStripVisible)
        check("picker.stripUnderSelection",
            view.stripFrame.maxY <= drawn.minY && abs(view.stripFrame.midX - drawn.midX) < 2,
            "\(view.stripFrame)")
        // "640 × 360 | Cancel | Record | ↩" needs well over 250 pt; a
        // narrower strip means its buttons were truncated.
        check("picker.stripNotTruncated", view.stripFrame.width >= 250, "\(view.stripFrame.size)")
        view.displayIfNeeded()
        snapshot(view, "picker-selected")

        // Drag inside the selection moves it (and clamps at the edge).
        if let down = mouse(.leftMouseDown, CGPoint(x: 500, y: 300)),
            let drag = mouse(.leftMouseDragged, CGPoint(x: 540, y: 250)),
            let up = mouse(.leftMouseUp, CGPoint(x: 540, y: 250))
        {
            view.mouseDown(with: down)
            view.mouseDragged(with: drag)
            view.mouseUp(with: up)
        }
        let moved = CGRect(x: 340, y: 150, width: 640, height: 360)
        check("picker.dragInsideMoves", view.selection == moved, "\(String(describing: view.selection))")

        // A click outside starts over; a stray click leaves no selection.
        if let down = mouse(.leftMouseDown, CGPoint(x: 50, y: 50)),
            let up = mouse(.leftMouseUp, CGPoint(x: 52, y: 51))
        {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
        check("picker.drawOutsideStartsOver", view.selection == nil)

        // Redraw and confirm with Return.
        if let down = mouse(.leftMouseDown, CGPoint(x: 100, y: 100)),
            let drag = mouse(.leftMouseDragged, CGPoint(x: 1380, y: 820)),
            let up = mouse(.leftMouseUp, CGPoint(x: 1380, y: 820))
        {
            view.mouseDown(with: down)
            view.mouseDragged(with: drag)
            view.mouseUp(with: up)
        }
        let final = AreaGeometry.selection(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1380, y: 820),
            within: CGRect(origin: .zero, size: screen.frame.size))
        check("picker.finalSelection", view.selection == final, "\(String(describing: view.selection))")
        if let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        {
            view.keyDown(with: enter)
        }
        check("picker.returnCommits", completed && result != nil)
        check("picker.dismissed", !areaPicker.isPresenting)
        if let result, let final {
            // Independent conversion: top-left y = display height - maxY.
            let expectedTop = screen.frame.height - final.maxY
            check("picker.resultDisplay", result.displayID == displayID)
            check("picker.resultTopLeftPoints",
                result.rect == CGRect(
                    x: final.minX, y: expectedTop, width: final.width, height: final.height),
                "\(result.rect)")
            report["picker.result"] = "display \(result.displayID) rect \(result.rect)"

            // Adopt it as the source and make sure the capture math accepts
            // it unchanged (SourceGeometry.area clamps only if out of range).
            apply(result)
            check("model.sourceKindIsArea", sourceKind == .area)
            check("model.areaFields",
                areaX == result.rect.minX && areaY == result.rect.minY
                    && areaWidth == result.rect.width && areaHeight == result.rect.height)
            let resolved = SourceGeometry.area(
                requested: AreaRect(x: areaX, y: areaY, width: areaWidth, height: areaHeight),
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height), scale: 1)
            check("model.areaAcceptedByCapture",
                resolved.areaRect == AreaRect(
                    x: areaX, y: areaY, width: areaWidth, height: areaHeight),
                "\(String(describing: resolved.areaRect))")
            check("model.eventOffset",
                resolved.eventOffsetXPx == areaX && resolved.eventOffsetYPx == areaY)
        }

        // Esc cancels a fresh picker without a result.
        var cancelledResult: AreaSelection? = AreaSelection(displayID: 0, rect: .zero)
        var cancelCompleted = false
        areaPicker.present(intent: .useSelection, initial: result) { selection in
            cancelledResult = selection
            cancelCompleted = true
        }
        try? await Task.sleep(for: .milliseconds(200))
        if let panel = areaPicker.panel(forDisplayID: displayID) {
            check("picker.initialSelectionShown",
                panel.pickerView.selection != nil && panel.pickerView.isStripVisible)
            if let esc = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)
            {
                panel.pickerView.keyDown(with: esc)
            }
        }
        check("picker.escCancels", cancelCompleted && cancelledResult == nil)
        check("picker.dismissedAfterEsc", !areaPicker.isPresenting)

        // MARK: Hotkey routing + transient Esc/Return interception
        // Same path the Carbon callback takes, minus the key press.
        HotkeyCenter.shared.dispatch(id: HotkeyAction.recordArea.rawValue)
        if displays.isEmpty {
            // No Screen Recording permission here: the route must land on
            // an actionable message in a visible main window, not silence.
            check("hotkey.recordAreaRoutesToPermissionMessage",
                statusMessage?.contains("Screen Recording") == true && isMainWindowVisible)
        } else {
            check("hotkey.recordAreaOpensPicker", areaPicker.isPresenting)
            check("hotkey.pickerInterceptsEscAndReturn",
                HotkeyCenter.shared.interceptedTransientKeys == [.escape, .returnKey])
            HotkeyCenter.shared.dispatch(id: HotkeyCenter.TransientKey.escape.rawValue)
            check("hotkey.escDismissesPicker", !areaPicker.isPresenting)
        }
        check("hotkey.transientKeysReleased", HotkeyCenter.shared.interceptedTransientKeys.isEmpty)
        var escFired = false
        HotkeyCenter.shared.intercept(.escape) { escFired = true }
        check("hotkey.escIntercepted", HotkeyCenter.shared.interceptedTransientKeys == [.escape])
        HotkeyCenter.shared.dispatch(id: HotkeyCenter.TransientKey.escape.rawValue)
        check("hotkey.escHandlerRuns", escFired)
        HotkeyCenter.shared.intercept(.escape, nil)
        check("hotkey.escReleased", HotkeyCenter.shared.interceptedTransientKeys.isEmpty)
        // Chords are still registered after the transient dance.
        check("hotkey.chordsIntact", HotkeyCenter.shared.registeredActions == expected)

        // MARK: Main window hide/show (what a hotkey start relies on)
        check("window.visibleAtStart", isMainWindowVisible)
        hideMainWindow()
        check("window.hidden", !isMainWindowVisible)
        showMainWindow()
        try? await Task.sleep(for: .milliseconds(200))
        check("window.restored", isMainWindowVisible)

        finish()
        NSApplication.shared.terminate(nil)
    }
}
