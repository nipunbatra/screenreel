import Foundation

/// Screen Recording permission has a failure mode the stock messages hide:
/// the TCC grant row stores the code-signing requirement of the binary that
/// was granted. A grant made against an older (for example ad-hoc-signed)
/// build keeps showing "on" in System Settings while every newer binary
/// fails validation, so capture errors out forever until the stale row is
/// deleted and the permission granted once against the current signature.
///
/// This is pure state logic (no CoreGraphics calls) so it is unit-testable;
/// the app feeds it the observed facts.
public enum ScreenPermissionState: Equatable, Sendable {
    /// Displays enumerate: capture works.
    case granted
    /// macOS reports no grant at all: ask the user to grant it.
    case denied
    /// macOS claims a grant exists (`CGPreflightScreenCaptureAccess` true)
    /// but enumeration still fails: the grant row belongs to a previous
    /// build. Fix: reset this app's row, re-grant once, relaunch.
    case staleGrant
    /// Permission was granted while the app was running; macOS applies it
    /// only to the next launch.
    case grantedAfterLaunch

    public static func diagnose(
        preflightGranted: Bool, displaysEnumerate: Bool
    ) -> ScreenPermissionState {
        if displaysEnumerate { return .granted }
        return preflightGranted ? .staleGrant : .denied
    }

    /// One-sentence operator guidance. Kept here so the wording is tested.
    public var guidance: String {
        switch self {
        case .granted:
            return ""
        case .denied:
            return "Screen Recording permission is off. Click Grant Permission — approve the prompt if one appears; otherwise System Settings opens so you can turn it on there."
        case .staleGrant:
            return "System Settings shows Screen Recording as on, but that approval belongs to an older build of this app. Click Repair Permission — you will approve one fresh prompt and it will stick from then on."
        case .grantedAfterLaunch:
            return "Screen Recording was granted while the app was running. macOS applies it at launch — click Relaunch."
        }
    }

    public var actionTitle: String {
        switch self {
        case .granted: return ""
        case .denied: return "Grant Permission"
        case .staleGrant: return "Repair Permission"
        case .grantedAfterLaunch: return "Relaunch"
        }
    }
}
