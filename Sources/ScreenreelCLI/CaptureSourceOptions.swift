import ArgumentParser
import CaptureCore
import CoreGraphics
import Foundation

struct CaptureSourceOptions: ParsableArguments {
    @Option(help: "Display ID (see 'screenreel env'). Defaults to the window's display or the first display.")
    var display: Int?
    @Option(help: "Record or screenshot one window by its numeric window ID.")
    var window: UInt32?
    @Option(help: "Capture one application's windows by bundle ID.")
    var app: String?
    @Option(help: "Capture a display area in points: x,y,width,height.")
    var area: String?

    func validate() throws {
        guard [window != nil, app != nil, area != nil].filter({ $0 }).count <= 1 else {
            throw ValidationError("Choose only one of --window, --app or --area.")
        }
        if let area {
            let values = area.split(separator: ",").compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw ValidationError("--area needs x,y,width,height in points, with positive width and height.")
            }
        }
    }

    func resolve() async throws -> CaptureConfiguration {
        try validate()
        let windows = window == nil ? [] : try await SCKCapture.availableWindows()
        let selectedWindow = windows.first { $0.windowID == window }
        if window != nil, selectedWindow == nil { throw CLIError.failed("Selected window is not available. List sources with 'screenreel sources'.") }
        let displays = try await SCKCapture.availableDisplays()
        let targetID = display ?? selectedWindow?.displayID.map(Int.init)
        guard let target = displays.first(where: { targetID == nil || Int($0.displayID) == targetID }) else {
            throw CLIError.failed("No matching display. Check 'screenreel sources' and Screen Recording permission.")
        }
        let scale = Double(target.widthPx) / Double(target.widthPoints)
        let geometry: SourceGeometry.Resolved
        let kind: CaptureSourceKind
        if let selectedWindow {
            kind = .window
            geometry = SourceGeometry.window(frame: selectedWindow.frame, displayBounds: CGDisplayBounds(target.displayID), scale: scale)
        } else if let area {
            kind = .area
            let v = area.split(separator: ",").map { Double($0)! }
            geometry = SourceGeometry.area(requested: .init(x: v[0], y: v[1], width: v[2], height: v[3]),
                displayWidthPoints: target.widthPoints, displayHeightPoints: target.heightPoints, scale: scale)
        } else {
            kind = app == nil ? .display : .application
            geometry = SourceGeometry.display(widthPoints: target.widthPoints, heightPoints: target.heightPoints, scale: scale)
        }
        return CaptureConfiguration(widthPx: geometry.widthPx, heightPx: geometry.heightPx,
            displayID: Int(target.displayID), sourceKind: kind, windowID: window, appBundleID: app,
            areaRect: geometry.areaRect, displayScale: geometry.scale,
            eventOffsetXPx: geometry.eventOffsetXPx, eventOffsetYPx: geometry.eventOffsetYPx,
            microphoneEnabled: false)
    }
}

struct Sources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List capturable displays, window IDs and application bundle IDs.")
    func run() async throws {
        for display in try await SCKCapture.availableDisplays() {
            print("display \(display.displayID)  \(display.widthPx)×\(display.heightPx) px")
        }
        for window in try await SCKCapture.availableWindows() {
            print("window \(window.windowID)  \(window.appName) — \(window.title)")
        }
        for app in try await SCKCapture.availableApps() { print("app \(app.bundleID)  \(app.name)") }
        for camera in CameraCapture.availableCameras() { print("camera \(camera.uniqueID)  \(camera.name)") }
    }
}
