import AppKit
import CaptureCore
import ProjectModel
import UniformTypeIdentifiers

extension AppModel {
    func takeScreenshot() {
        guard case .start = mode, !isTakingScreenshot,
              let display = displays.first(where: { $0.displayID == selectedDisplayID }) ?? displays.first,
              let configuration = makeConfiguration(display: display) else { return }
        isTakingScreenshot = true
        statusMessage = nil
        hideMainWindow()
        Task {
            defer { isTakingScreenshot = false }
            do {
                // Give WindowServer time to remove recorder chrome from area/display captures.
                try await Task.sleep(for: .milliseconds(200))
                let image = try await SCKCapture.screenshot(configuration: configuration)
                let png = try await Task.detached(priority: .userInitiated) {
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw ScreenreelError.invariantViolated("Could not encode the screenshot as PNG.")
                    }
                    return data
                }.value
                showMainWindow()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "Screen Reel \(RFC3339.now().replacingOccurrences(of: ":", with: "-" )).png"
                panel.message = "\(image.width) × \(image.height) pixels · PNG"
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try png.write(to: url, options: .atomic)
                statusMessage = "Saved \(url.lastPathComponent) · \(image.width) × \(image.height) pixels"
            } catch {
                showMainWindow()
                statusMessage = "Screenshot failed: \(error.localizedDescription)"
            }
        }
    }
}
