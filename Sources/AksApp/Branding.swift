import Foundation

/// Single source of truth for the user-facing product name.
///
/// Rebrand in one place: `APP_NAME="NewName" Scripts/make-app.sh` stamps the
/// bundle's display name, and every UI string reads it from here. On-disk
/// identifiers (`in.aks.project`, the `.aks` package extension, bundle id)
/// deliberately do NOT change with the display name — existing projects stay
/// readable and permissions stay bound.
enum Branding {
    static let displayName: String = {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            !name.isEmpty
        {
            return name
        }
        return "Screenreel"
    }()

    static let tagline = "The recording studio that never loses a take"
}
