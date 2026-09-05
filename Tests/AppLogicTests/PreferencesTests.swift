import Foundation
import XCTest

@testable import AppSupport

final class PreferencesTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.nipunbatra.screenreel.tests.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFreshInstallDefaults() {
        let prefs = Preferences()
        XCTAssertTrue(prefs.showInMenuBar)
        XCTAssertEqual(prefs.countdownSeconds, 3)
        XCTAssertTrue(prefs.openEditorAfterRecording)
        XCTAssertNil(prefs.recordingsFolderPath)
        XCTAssertEqual(prefs.hotkey(for: .toggleRecording), .commandShiftR)
        XCTAssertEqual(prefs.hotkey(for: .togglePause), .commandShiftP)
        XCTAssertEqual(prefs.hotkey(for: .recordArea), .commandShiftA)
    }

    func testEmptyDefaultsLoadAsFreshInstall() {
        XCTAssertEqual(PreferencesStore(defaults: defaults).load(), Preferences())
    }

    func testRoundTrip() {
        var prefs = Preferences()
        prefs.showInMenuBar = false
        prefs.countdownSeconds = 5
        prefs.openEditorAfterRecording = false
        prefs.recordingsFolderPath = "/Users/someone/Screencasts"
        prefs.assign(.controlOptionR, to: .toggleRecording)
        prefs.assign(.off, to: .togglePause)
        prefs.assign(.commandShift3, to: .recordArea)

        let store = PreferencesStore(defaults: defaults)
        store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
    }

    func testClearingTheFolderRemovesTheKey() {
        let store = PreferencesStore(defaults: defaults)
        var prefs = Preferences()
        prefs.recordingsFolderPath = "/tmp/x"
        store.save(prefs)
        prefs.recordingsFolderPath = nil
        store.save(prefs)
        XCTAssertNil(defaults.object(forKey: PreferencesStore.Key.recordingsFolderPath))
        XCTAssertNil(store.load().recordingsFolderPath)
    }

    func testHandEditedValuesAreSanitized() {
        defaults.set(7, forKey: PreferencesStore.Key.countdownSeconds)
        defaults.set("", forKey: PreferencesStore.Key.recordingsFolderPath)
        defaults.set("notAPreset", forKey: HotkeyAction.recordArea.preferenceKey)
        let prefs = PreferencesStore(defaults: defaults).load()
        XCTAssertEqual(prefs.countdownSeconds, 3)
        XCTAssertNil(prefs.recordingsFolderPath)
        XCTAssertEqual(prefs.hotkey(for: .recordArea), .commandShiftA)
    }

    func testAssigningAChordStealsItFromTheOtherAction() {
        var prefs = Preferences()
        prefs.assign(.commandShiftR, to: .togglePause)
        XCTAssertEqual(prefs.hotkey(for: .togglePause), .commandShiftR)
        XCTAssertEqual(prefs.hotkey(for: .toggleRecording), .off,
            "the same chord cannot drive two actions")
        // Off never steals anything.
        prefs.assign(.off, to: .recordArea)
        XCTAssertEqual(prefs.hotkey(for: .togglePause), .commandShiftR)
    }

    func testCountdownChoices() {
        XCTAssertEqual(Preferences.countdownChoices, [0, 3, 5])
    }
}
