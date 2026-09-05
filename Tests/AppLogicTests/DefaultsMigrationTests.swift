import XCTest

@testable import AppSupport

final class DefaultsMigrationTests: XCTestCase {
    private var legacyName: String!
    private var targetName: String!

    override func setUp() {
        super.setUp()
        legacyName = "com.nipunbatra.screenreel.tests.legacy.\(UUID().uuidString)"
        targetName = "com.nipunbatra.screenreel.tests.target.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: legacyName)
        UserDefaults.standard.removePersistentDomain(forName: targetName)
        super.tearDown()
    }

    private func legacy(_ values: [String: Any]) -> String {
        UserDefaults.standard.setPersistentDomain(values, forName: legacyName)
        return legacyName
    }

    func testCarriesLicenseAndPreferencesOnceOnly() {
        let legacy = legacy([
            "license.key": "SR1-abc",
            "preferences.countdownSeconds": 5,
            "updates.automatic": false,
            "NSWindow Frame Main": "1 2 3 4",  // never carried
        ])
        let target = UserDefaults(suiteName: targetName)!
        target.removePersistentDomain(forName: targetName)

        let copied = DefaultsMigration.migrateIfNeeded(into: target, legacyDomain: legacy)
        XCTAssertEqual(copied, ["license.key", "preferences.countdownSeconds", "updates.automatic"])
        XCTAssertEqual(target.string(forKey: "license.key"), "SR1-abc")
        XCTAssertEqual(target.integer(forKey: "preferences.countdownSeconds"), 5)
        XCTAssertFalse(target.bool(forKey: "updates.automatic"))
        XCTAssertNil(target.object(forKey: "NSWindow Frame Main"))
        XCTAssertTrue(target.bool(forKey: DefaultsMigration.markerKey))

        // A second launch copies nothing, even if the legacy domain changed.
        UserDefaults.standard.setPersistentDomain(["license.key": "SR1-other"], forName: legacy)
        XCTAssertEqual(DefaultsMigration.migrateIfNeeded(into: target, legacyDomain: legacy), [])
        XCTAssertEqual(target.string(forKey: "license.key"), "SR1-abc")
    }

    func testExistingValuesInTheNewDomainWin() {
        let legacy = legacy(["license.key": "SR1-old"])
        let target = UserDefaults(suiteName: targetName)!
        target.removePersistentDomain(forName: targetName)
        target.set("SR1-new", forKey: "license.key")
        let copied = DefaultsMigration.migrateIfNeeded(into: target, legacyDomain: legacy)
        XCTAssertEqual(copied, [])
        XCTAssertEqual(target.string(forKey: "license.key"), "SR1-new")
    }

    func testNoLegacyDomainStillSetsTheMarker() {
        let target = UserDefaults(suiteName: targetName)!
        target.removePersistentDomain(forName: targetName)
        XCTAssertEqual(DefaultsMigration.migrateIfNeeded(into: target, legacyDomain: nil), [])
        XCTAssertTrue(target.bool(forKey: DefaultsMigration.markerKey))
    }
}
