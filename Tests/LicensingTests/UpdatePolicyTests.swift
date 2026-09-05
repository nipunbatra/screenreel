import Foundation
import XCTest

@testable import Licensing

/// Version ordering, GitHub release parsing from fixture JSON, and the
/// automatic-check cadence. No network is involved anywhere in this target.
final class UpdatePolicyTests: XCTestCase {

    // MARK: SemanticVersion

    func testParsesTagsAndShortForms() {
        XCTAssertEqual(SemanticVersion("v0.2.0"), SemanticVersion(0, 2, 0))
        XCTAssertEqual(SemanticVersion("0.2.0"), SemanticVersion(0, 2, 0))
        XCTAssertEqual(SemanticVersion("V1.2"), SemanticVersion(1, 2, 0))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(3, 0, 0))
        XCTAssertEqual(SemanticVersion(" 1.2.3\n"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("1.2.3-beta.2"), SemanticVersion(1, 2, 3, prerelease: ["beta", "2"]))
        XCTAssertEqual(SemanticVersion("1.2.3+build.7"), SemanticVersion(1, 2, 3), "build metadata ignored")
        XCTAssertEqual(SemanticVersion("1.2.3-rc.1+sha"), SemanticVersion(1, 2, 3, prerelease: ["rc", "1"]))
    }

    func testRejectsNonVersions() {
        for text in ["", "v", "latest", "1.2.3.4", "1..2", "1.x", "1.2-", "1.2-a..b", "abc"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrdering() {
        let versions = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                        "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
            .map { SemanticVersion($0)! }
        for (index, lower) in versions.enumerated() {
            for higher in versions[(index + 1)...] {
                XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
                XCTAssertFalse(higher < lower)
            }
            XCTAssertFalse(lower < lower)
        }
        XCTAssertEqual(SemanticVersion("v0.2.0")?.description, "0.2.0")
        XCTAssertEqual(SemanticVersion("1.0.0-rc.1")?.description, "1.0.0-rc.1")
    }

    // MARK: ReleaseInfo

    private let fixture = """
        {
          "html_url": "https://github.com/nipunbatra/screenreel/releases/tag/v0.3.0",
          "tag_name": "v0.3.0",
          "name": "Screenreel 0.3.0",
          "body": "## Changes\\n- things",
          "assets": [
            {"name": "Screenreel.dmg", "browser_download_url": "https://github.com/nipunbatra/screenreel/releases/download/v0.3.0/Screenreel.dmg"},
            {"name": "Screenreel-0.3.0.dmg", "browser_download_url": "https://github.com/nipunbatra/screenreel/releases/download/v0.3.0/Screenreel-0.3.0.dmg"},
            {"name": "checksums.txt", "browser_download_url": "https://github.com/nipunbatra/screenreel/releases/download/v0.3.0/checksums.txt"},
            {"name": "broken", "browser_download_url": 12}
          ]
        }
        """

    func testParsesGitHubLatestRelease() throws {
        let release = try ReleaseInfo(githubJSON: Data(fixture.utf8))
        XCTAssertEqual(release.tagName, "v0.3.0")
        XCTAssertEqual(release.version, SemanticVersion(0, 3, 0))
        XCTAssertEqual(release.assets.count, 3, "malformed asset entries are skipped")
        XCTAssertEqual(release.dmgAsset?.name, "Screenreel-0.3.0.dmg", "versioned DMG preferred")
        XCTAssertEqual(release.downloadURL.absoluteString,
                       "https://github.com/nipunbatra/screenreel/releases/download/v0.3.0/Screenreel-0.3.0.dmg")
        XCTAssertEqual(release.body, "## Changes\n- things")
    }

    func testDownloadFallsBackToReleasePageWithoutDMG() throws {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://example.org/rel","assets":[{"name":"a.zip","browser_download_url":"https://example.org/a.zip"}]}"#
        let release = try ReleaseInfo(githubJSON: Data(json.utf8))
        XCTAssertNil(release.dmgAsset)
        XCTAssertEqual(release.downloadURL.absoluteString, "https://example.org/rel")
        XCTAssertNil(release.body)
    }

    func testReleaseDecodeErrors() {
        XCTAssertThrowsError(try ReleaseInfo(githubJSON: Data("not json".utf8))) {
            XCTAssertEqual($0 as? ReleaseInfo.DecodeError, .notJSON)
        }
        XCTAssertThrowsError(try ReleaseInfo(githubJSON: Data(#"{"html_url":"https://x"}"#.utf8))) {
            XCTAssertEqual($0 as? ReleaseInfo.DecodeError, .missingField("tag_name"))
        }
        XCTAssertThrowsError(try ReleaseInfo(githubJSON: Data(#"{"tag_name":"v1"}"#.utf8))) {
            XCTAssertEqual($0 as? ReleaseInfo.DecodeError, .missingField("html_url"))
        }
    }

    // MARK: UpdatePolicy

    func testAutomaticCheckCadence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(UpdatePolicy.automaticCheckIsDue(enabled: false, lastCheck: nil, now: now))
        XCTAssertTrue(UpdatePolicy.automaticCheckIsDue(enabled: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UpdatePolicy.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdatePolicy.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdatePolicy.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(+86_400), now: now),
                      "a clock moved backwards must not suppress checks")
    }

    func testEvaluateOutcomes() throws {
        let latest = try ReleaseInfo(githubJSON: Data(fixture.utf8))
        let installed = SemanticVersion(0, 2, 0)
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: installed, latest: latest, skippedVersion: nil, manual: false),
            .updateAvailable(SemanticVersion(0, 3, 0)))
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: installed, latest: latest, skippedVersion: "0.3.0", manual: false),
            .skipped(SemanticVersion(0, 3, 0)))
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: installed, latest: latest, skippedVersion: "0.3.0", manual: true),
            .updateAvailable(SemanticVersion(0, 3, 0)), "a manual check ignores the skip")
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: installed, latest: latest, skippedVersion: "0.2.5", manual: false),
            .updateAvailable(SemanticVersion(0, 3, 0)), "skipping an older version does not hide a newer one")
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: SemanticVersion(0, 3, 0), latest: latest, skippedVersion: nil, manual: true),
            .upToDate)
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: SemanticVersion(0, 4, 0), latest: latest, skippedVersion: nil, manual: true),
            .upToDate, "a dev build ahead of the latest release is not 'outdated'")
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: SemanticVersion(0, 3, 0, prerelease: ["beta"]), latest: latest, skippedVersion: nil, manual: false),
            .updateAvailable(SemanticVersion(0, 3, 0)), "the release supersedes its own prerelease")

        let oddTag = ReleaseInfo(tagName: "latest", htmlURL: URL(string: "https://example.org")!)
        XCTAssertEqual(
            UpdatePolicy.evaluate(installed: installed, latest: oddTag, skippedVersion: nil, manual: true),
            .unparseableTag("latest"))
    }
}
