import Foundation

/// Single source of truth for the user-facing product name.
///
/// Rebrand in one place: `APP_NAME="NewName" Scripts/make-app.sh` stamps the
/// bundle's display name, and every UI string reads it from here. On-disk
/// identifiers (`com.nipunbatra.screenreel.project`, the `.screenreel` package extension, bundle id)
/// deliberately do NOT change with the display name — existing projects stay
/// readable and permissions stay bound.
enum Branding {
    static let displayName: String = {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            !name.isEmpty
        {
            return name
        }
        return "Screen Reel"
    }()

    static let tagline = "Record clearly. Make it yours."

    // MARK: Distribution

    /// GitHub repository that hosts releases. The update check queries its
    /// "latest release" endpoint and the license/update dialogs link to it.
    static let repositorySlug = "nipunbatra/screenreel"

    static var repositoryURL: URL { URL(string: "https://github.com/\(repositorySlug)")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repositorySlug)/releases/latest")! }
    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!
    }

    /// Where "Buy a License…" sends people. `nil` (the default) hides every
    /// purchase button in the app — pricing and the storefront are not
    /// decided yet. Set this to the checkout page when they are.
    static let purchaseURL: URL? = nil
}
