import Foundation

/// The subset of a GitHub "latest release" response the update check needs.
/// Decoded from `GET /repos/{owner}/{repo}/releases/latest`; the network
/// call itself lives in the app so this stays testable from fixture JSON.
public struct ReleaseInfo: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public var name: String
        public var downloadURL: URL
        public init(name: String, downloadURL: URL) {
            self.name = name
            self.downloadURL = downloadURL
        }
    }

    public var tagName: String
    public var htmlURL: URL
    public var assets: [Asset]
    /// Release notes body (Markdown), if present.
    public var body: String?

    public init(tagName: String, htmlURL: URL, assets: [Asset] = [], body: String? = nil) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
        self.body = body
    }

    /// `tag_name` with its `v` prefix stripped, or nil when the tag is not a
    /// version (a release the checker must ignore rather than misreport).
    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// The first `.dmg` asset; a versioned name wins over an unversioned
    /// alias when both are attached.
    public var dmgAsset: Asset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        return dmgs.first { $0.name.contains(where: \.isNumber) } ?? dmgs.first
    }

    /// Where "Download" should send the user: the DMG when there is one,
    /// otherwise the release page.
    public var downloadURL: URL { dmgAsset?.downloadURL ?? htmlURL }

    public enum DecodeError: Error, Equatable, Sendable {
        case notJSON
        case missingField(String)
    }

    public init(githubJSON data: Data) throws(DecodeError) {
        guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else {
            throw .notJSON
        }
        guard let tag = object["tag_name"] as? String else { throw .missingField("tag_name") }
        guard let html = object["html_url"] as? String, let htmlURL = URL(string: html) else {
            throw .missingField("html_url")
        }
        var assets: [Asset] = []
        for case let entry as [String: Any] in (object["assets"] as? [Any]) ?? [] {
            guard let name = entry["name"] as? String,
                let link = entry["browser_download_url"] as? String,
                let url = URL(string: link)
            else { continue }
            assets.append(Asset(name: name, downloadURL: url))
        }
        self.init(tagName: tag, htmlURL: htmlURL, assets: assets, body: object["body"] as? String)
    }
}
