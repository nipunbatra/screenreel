import AppKit
import Licensing
import SwiftUI

/// Paste-and-validate sheet for license keys. Shows the current status,
/// licensee, tier/seats, and the update window against this build's date.
/// A "Buy a License…" button appears only when `Branding.purchaseURL` is
/// set, so an undecided storefront never shows a dead button.
struct LicenseView: View {
    @Environment(Entitlements.self) private var entitlements
    @State private var keyText = ""
    @State private var error: LicenseError?
    @State private var justActivated = false
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Branding.displayName) License")
                        .font(.title2.weight(.semibold))
                    Text("Version \(AppBuildInfo.versionString) · built \(Self.dateFormatter.string(from: AppBuildInfo.buildDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            statusCard

            VStack(alignment: .leading, spacing: 8) {
                Text(entitlements.isLicensed ? "Replace key" : "Enter a license key")
                    .font(.headline)
                TextEditor(text: $keyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 76)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(error == nil ? Color.clear : Color.red.opacity(0.7)))
                if let error {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if justActivated {
                    Label("License activated. Thank you.", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("Keys look like SR1-…-… and validate on this Mac; nothing is sent anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Paste") { pasteFromClipboard() }
                    Button("Activate") { activate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if entitlements.isLicensed {
                        Button("Remove License", role: .destructive) {
                            entitlements.removeLicense()
                            justActivated = false
                            error = nil
                        }
                    }
                }
            }

            if LicensePublicKeys.isPlaceholder {
                Label(
                    "Developer note: this build has no production public key, so no key can activate. See docs/DISTRIBUTION.md.",
                    systemImage: "hammer")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if let purchaseURL = Branding.purchaseURL {
                    Button("Buy a License…") { NSWorkspace.shared.open(purchaseURL) }
                }
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entitlements.status {
            case .unlicensed:
                Label("No license installed", systemImage: "circle.dashed")
                    .font(.headline)
                Text("\(Branding.displayName) is fully usable without a license. Nothing is locked.")
                    .foregroundStyle(.secondary)
            case .valid(let license):
                Label("Licensed", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Licensee").foregroundStyle(.secondary)
                        Text(license.email)
                    }
                    GridRow {
                        Text("Tier").foregroundStyle(.secondary)
                        Text(Self.tierLabel(license))
                    }
                    GridRow {
                        Text("Issued").foregroundStyle(.secondary)
                        Text(Self.dateFormatter.string(from: license.issuedAt))
                    }
                    GridRow {
                        Text("Updates").foregroundStyle(.secondary)
                        Text(updatesLine(for: license))
                    }
                }
                .font(.callout)
            case .invalid(let reason):
                Label("Installed key is not valid", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(reason.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func updatesLine(for license: License) -> String {
        guard let until = license.updatesUntil else { return "All future versions" }
        let day = Self.dateFormatter.string(from: until)
        if license.updatesCovered(buildDate: AppBuildInfo.buildDate) {
            return "Through \(day) — this build is covered"
        }
        return "Through \(day) — this build is newer than your update window"
    }

    private static func tierLabel(_ license: License) -> String {
        switch license.tier {
        case .personal: return "Personal"
        case .team: return license.seats == 1 ? "Team · 1 seat" : "Team · \(license.seats) seats"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            keyText = text
            error = nil
        }
    }

    private func activate() {
        do {
            try entitlements.apply(key: keyText)
            error = nil
            justActivated = true
            keyText = ""
        } catch {
            self.error = error
            justActivated = false
        }
    }
}

/// Presents ``LicenseView`` as a sheet on the frontmost window, or as a
/// standalone window when none is open (e.g. before a project loads).
@MainActor
final class LicenseSheetController {
    static let shared = LicenseSheetController()

    private var window: NSWindow?
    private var parent: NSWindow?

    func present() {
        if let window {
            if let parent { parent.makeKeyAndOrderFront(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: LicenseView(onDone: { [weak self] in self?.dismiss() })
                .environment(Entitlements.shared)
                .preferredColorScheme(.dark))
        let window = NSWindow(contentViewController: host)
        window.title = "\(Branding.displayName) License"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.window = window

        let candidate = NSApp.keyWindow ?? NSApp.mainWindow
        if let candidate, candidate.isVisible, !(candidate is NSPanel) {
            parent = candidate
            candidate.beginSheet(window) { [weak self] _ in
                self?.window = nil
                self?.parent = nil
            }
        } else {
            parent = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func dismiss() {
        guard let window else { return }
        if let parent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        self.window = nil
        self.parent = nil
    }
}

/// Menu items for the app menu: license entry plus the update check. Added
/// from `AksApp.swift` via `CommandGroup(after: .appInfo)`.
struct DistributionCommands: View {
    @AppStorage(UpdateChecker.automaticKey) private var automaticUpdates = true

    var body: some View {
        Button("Enter License…") {
            LicenseSheetController.shared.present()
        }
        Divider()
        Button("Check for Updates…") {
            UpdateChecker.shared.checkNow()
        }
        Toggle("Check for Updates Automatically", isOn: $automaticUpdates)
        Divider()
    }
}
