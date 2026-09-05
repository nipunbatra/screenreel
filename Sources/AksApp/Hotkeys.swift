import AppKit
import AppSupport
import Carbon.HIToolbox

/// Global keyboard shortcuts through Carbon's `RegisterEventHotKey`: they
/// fire while any app is frontmost, need no Accessibility or Input
/// Monitoring grant, and are still supported on macOS 15. One event
/// handler is installed on the application target; each action registers
/// its own chord and is looked up by the hot-key ID it was registered with.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlerRef: EventHandlerRef?
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var onAction: (@MainActor (HotkeyAction) -> Void)?
    /// Chords the OS refused (typically held by another app), keyed by
    /// action, so Settings can say so instead of silently doing nothing.
    private(set) var failures: [HotkeyAction: OSStatus] = [:]

    private init() {}

    func setHandler(_ handler: @escaping @MainActor (HotkeyAction) -> Void) {
        onAction = handler
    }

    /// Actions whose chord is currently registered with the OS.
    var registeredActions: Set<HotkeyAction> { Set(registrations.keys) }

    /// (Re)register every action's chord. Unregisters first so a changed
    /// preset never leaves the old chord live.
    func apply(_ preferences: Preferences) {
        installHandlerIfNeeded()
        unregisterAll()
        failures = [:]
        for action in HotkeyAction.allCases {
            guard let combo = preferences.hotkey(for: action).combo else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: hotkeySignature, id: action.rawValue)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers.rawValue, hotKeyID,
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registrations[action] = ref
            } else {
                failures[action] = status
            }
        }
    }

    func unregisterAll() {
        for ref in registrations.values {
            UnregisterEventHotKey(ref)
        }
        registrations = [:]
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    fileprivate func dispatch(id: UInt32) {
        guard let action = HotkeyAction(rawValue: id) else { return }
        onAction?(action)
    }
}

/// Four-char tag on every hot key we register, so the handler ignores IDs
/// that are not ours.
private let hotkeySignature: OSType = "AKSH".utf8.reduce(0) { ($0 << 8) | OSType($1) }

/// Carbon calls this on the main thread with no context pointer we could
/// trust across actors; hop onto the main actor explicitly and let the
/// center route by ID.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    guard hotKeyID.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    Task { @MainActor in
        HotkeyCenter.shared.dispatch(id: id)
    }
    return noErr
}
