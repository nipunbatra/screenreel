// Small, public-safe native app used as the SUBJECT of real ScreenCaptureKit recordings.
// It never manufactures recording frames. Record its window with `screenreel record --window`.
import AppKit

@MainActor
final class WaveView: NSView {
    var shape = 0
    var phase: Double = 0
    var noisy = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.975, green: 0.969, blue: 0.942, alpha: 1).setFill()
        bounds.fill()
        let ink = NSColor(srgbRed: 0.15, green: 0.19, blue: 0.17, alpha: 1)
        let muted = NSColor(srgbRed: 0.40, green: 0.45, blue: 0.40, alpha: 1)
        func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor? = nil) {
            (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ink])
        }
        text("WAVE LAB", 40, 27, 12, .semibold, muted)
        text("A little physics, made visible.", 40, 66, 34, .medium)
        text("Three shapes. One frequency. See what changes.", 41, 114, 15, .regular, muted)
        let rect = CGRect(x: 40, y: 166, width: bounds.width - 80, height: 244)
        NSColor(srgbRed: 0.90, green: 0.925, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSColor(srgbRed: 0.72, green: 0.78, blue: 0.68, alpha: 1).setStroke()
        let grid = NSBezierPath()
        for i in 1..<10 {
            let x = rect.minX + CGFloat(i) * rect.width / 10
            grid.move(to: .init(x: x, y: rect.minY + 20)); grid.line(to: .init(x: x, y: rect.maxY - 20))
        }
        grid.move(to: .init(x: rect.minX + 20, y: rect.midY)); grid.line(to: .init(x: rect.maxX - 20, y: rect.midY))
        grid.lineWidth = 0.6; grid.stroke()
        let line = NSBezierPath()
        for i in 0...800 {
            let angle = Double(i) / 800 * 6 * Double.pi - phase
            let sine = sin(angle)
            let value = shape == 0 ? sine : (shape == 1 ? tanh(sine * 6) : 2 / .pi * asin(sine))
            let noise = noisy ? 0.09 * sin(Double(i) * 3.13 + phase * 17) : 0
            let point = NSPoint(x: rect.minX + 20 + CGFloat(i) / 800 * (rect.width - 40),
                                y: rect.midY - (value + noise) * 71)
            if i == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        ink.setStroke(); line.lineWidth = 2.5; line.lineJoinStyle = .round; line.stroke()
        text(["Sine / a smooth oscillation", "Square / a sharper transition", "Triangle / a steady rise and fall"][shape], 58, 181, 12, .medium)
        text("TIME →", bounds.width - 120, 379, 10, .medium, muted)
        text("Try a waveform", 40, 440, 12, .medium, muted)
        text("Native Mac demo · recorded with Screen Reel", 40, 512, 11, .regular, muted)
    }
}

@MainActor
final class Demo: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let wave = WaveView(frame: .init(x: 0, y: 0, width: 960, height: 546))
    var timer: Timer?
    var sound: NSSound?
    var activity: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Live waveform demonstration")
        window = NSWindow(contentRect: wave.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wave Lab — Screen Reel demo"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = wave
        window.center()
        for (i, title) in ["Sine", "Square", "Triangle"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(changeShape(_:)))
            button.tag = i; button.bezelStyle = .rounded
            button.frame = .init(x: 40 + i * 112, y: 460, width: 100, height: 30)
            wave.addSubview(button)
        }
        let noise = NSButton(checkboxWithTitle: "Show noise", target: self, action: #selector(changeNoise(_:)))
        noise.frame = .init(x: 412, y: 462, width: 140, height: 26); wave.addSubview(noise)
        let voice = NSButton(title: "Play demo voice", target: self, action: #selector(playVoice))
        voice.bezelStyle = .rounded; voice.frame = .init(x: 734, y: 459, width: 184, height: 32); wave.addSubview(voice)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        print("WINDOW_ID=\(window.windowNumber)")
        fflush(stdout)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wave.phase += 0.035
                self.wave.needsDisplay = true
            }
        }
    }
    @objc func changeShape(_ button: NSButton) { wave.shape = button.tag; wave.needsDisplay = true }
    @objc func changeNoise(_ button: NSButton) { wave.noisy = button.state == .on }
    @objc func playVoice() {
        guard CommandLine.arguments.count > 1 else { return }
        sound?.stop()
        sound = NSSound(contentsOfFile: CommandLine.arguments[1], byReference: true)
        sound?.play()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WaveLab {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Demo()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
