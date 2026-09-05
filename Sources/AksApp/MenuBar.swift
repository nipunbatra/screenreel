import AppKit
import AppSupport
import Observation

/// The always-on status item: record from any app without opening the
/// main window, and control a running recording. AppKit rather than
/// SwiftUI's MenuBarExtra so the icon can turn red while recording, the
/// items can show the global hotkey glyphs, and the elapsed time can tick
/// in the bar itself.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var elapsedTimer: Timer?
    private var elapsedItem: NSMenuItem?

    var isInserted: Bool { statusItem != nil }
    var statusButtonTitle: String { statusItem?.button?.title ?? "" }
    var statusSymbolIsTemplate: Bool? { statusItem?.button?.image?.isTemplate }

    /// The menu as it would open right now, for self-tests: separators
    /// as "—", submenus as "Title > child | child".
    func currentMenuTitles() -> [String] {
        rebuildMenu()
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if let submenu = item.submenu {
                return item.title + " > " + submenu.items.map(\.title).joined(separator: " | ")
            }
            return item.title
        }
    }

    func bind(model: AppModel) {
        self.model = model
        menu.delegate = self
        menu.autoenablesItems = false
        observe()
    }

    /// Track the model properties the status item depends on; re-arm
    /// after each change (observation tracking fires once per change set).
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            self.apply(model: model)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func apply(model: AppModel) {
        let recording = model.isRecordingMode
        let paused = model.isPaused
        let wanted = model.preferences.showInMenuBar || recording
        if wanted {
            ensureStatusItem()
        } else {
            removeStatusItem()
        }
        guard let button = statusItem?.button else {
            stopElapsedTimer()
            return
        }
        let symbol: String
        let tint: NSColor?
        if recording {
            symbol = paused ? "pause.circle.fill" : "record.circle.fill"
            tint = paused ? .systemOrange : .systemRed
        } else {
            symbol = "record.circle"
            tint = nil
        }
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: Branding.displayName)
        if let tint {
            let colored = base?.withSymbolConfiguration(.init(paletteColors: [tint]))
            colored?.isTemplate = false
            button.image = colored
        } else {
            base?.isTemplate = true
            button.image = base
        }
        button.imagePosition = .imageLeading
        if recording {
            startElapsedTimer()
            updateElapsed()
        } else {
            stopElapsedTimer()
            button.title = ""
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        item.button?.toolTip = Branding.displayName
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        stopElapsedTimer()
    }

    // MARK: Elapsed time

    private func startElapsedTimer() {
        guard elapsedTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.updateElapsed()
            }
        }
        // .common so it keeps ticking while the menu is open (menu
        // tracking runs the event-tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsed() {
        guard let model, let button = statusItem?.button else { return }
        let text = model.elapsedText
        button.attributedTitle = NSAttributedString(
            string: " " + text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize, weight: .medium)
            ])
        elapsedItem?.title = (model.isPaused ? "Paused · " : "Recording · ") + text
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        elapsedItem = nil
        guard let model else { return }
        let prefs = model.preferences

        switch model.mode {
        case .recording:
            let status = disabledItem("Recording")
            menu.addItem(status)
            elapsedItem = status
            updateElapsed()
            menu.addItem(item(
                model.isPaused ? "Resume" : "Pause", #selector(togglePause),
                hotkey: prefs.hotkey(for: .togglePause)))
            menu.addItem(item(
                "Stop Recording", #selector(stopRecording),
                hotkey: prefs.hotkey(for: .toggleRecording)))
        case .countdown(let remaining):
            menu.addItem(disabledItem("Starting in \(remaining)…"))
            menu.addItem(item("Start Now", #selector(startNow)))
            menu.addItem(item("Cancel Countdown", #selector(cancelCountdown)))
        case .start, .editor:
            menu.addItem(item(
                Self.recordTitle(for: model), #selector(recordNow),
                hotkey: prefs.hotkey(for: .toggleRecording)))
            menu.addItem(item("Record Window…", #selector(recordWindow)))
            menu.addItem(item(
                "Record Area…", #selector(recordArea),
                hotkey: prefs.hotkey(for: .recordArea)))
            menu.addItem(.separator())
            menu.addItem(recentItem(model))
        }

        menu.addItem(.separator())
        menu.addItem(item("Open \(Branding.displayName)", #selector(openApp)))
        let settings = item("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = item("Quit \(Branding.displayName)", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// "Record Screen" when the start screen is set to a display; honest
    /// about what else the current selection would record.
    static func recordTitle(for model: AppModel) -> String {
        switch model.sourceKind {
        case .display: return "Record Screen"
        case .window: return "Record Selected Window"
        case .area: return "Record Selected Area"
        case .application: return "Record Selected App"
        }
    }

    private func recentItem(_ model: AppModel) -> NSMenuItem {
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent")
        submenu.autoenablesItems = false
        let cards = model.projectCards.prefix(5)
        if cards.isEmpty {
            submenu.addItem(disabledItem("No Recordings"))
        }
        for card in cards {
            let entry = item(card.name, #selector(openRecent(_:)))
            entry.representedObject = card.url
            submenu.addItem(entry)
        }
        recent.submenu = submenu
        return recent
    }

    private func item(_ title: String, _ action: Selector, hotkey: HotkeyPreset? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let combo = hotkey?.combo {
            // Display only: the chord itself is delivered by the Carbon
            // hot key, which fires no matter which app is frontmost.
            item.keyEquivalent = combo.keyEquivalent
            item.keyEquivalentModifierMask = Self.modifierFlags(combo.modifiers)
        }
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func modifierFlags(_ modifiers: CarbonModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: Actions

    @objc private func recordNow() { model?.startCountdown() }
    @objc private func recordWindow() { model?.recordWindowFromMenuBar() }
    @objc private func recordArea() { model?.presentAreaPicker(thenRecord: true) }
    @objc private func togglePause() { model?.togglePause() }
    @objc private func stopRecording() { model?.stopRecording() }
    @objc private func startNow() { model?.skipCountdown() }
    @objc private func cancelCountdown() { model?.cancelCountdown() }
    @objc private func openApp() { model?.showMainWindow() }
    @objc private func openSettings() { model?.openSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        model?.openProjectFromMenuBar(url)
    }
}
