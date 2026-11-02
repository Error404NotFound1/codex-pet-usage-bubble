import AppKit
import Foundation

// A tiny, click-through macOS overlay that follows the ChatGPT desktop pet
// and displays the remaining Codex five-hour and weekly usage allowances.

private struct LimitWindow {
    let remaining: Int
    let durationMinutes: Int?
    let resetsAt: Date?
}

private struct UsageSnapshot {
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    let fetchedAt: Date
    let plan: String?
}

private enum UsageState {
    case loading(String)
    case ready(UsageSnapshot)
    case error(String, Date?)
}

private final class UsageClient {
    var onState: ((UsageState) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var restartWorkItem: DispatchWorkItem?
    private var nextID = 2
    private var lastSuccess: Date?
    private var lastResponseAt: Date?
    private var serverStartedAt = Date.distantPast
    private var serverExecutableModifiedAt: Date?
    private var lineBuffer = Data()

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.onState?(.loading("Connecting…"))
        }
        launchServer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
    }

    func refreshNow() {
        guard process?.isRunning == true else {
            launchServer()
            return
        }
        requestUsage()
    }

    private func codexPath() -> String? {
        var candidates: [String] = []

        if let bundleURL = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .first?.bundleURL {
            let resources = bundleURL.appendingPathComponent("Contents/Resources")
            candidates.append(contentsOf: [
                resources.appendingPathComponent("codex-cli/bin/codex").path,
                resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex").path,
                resources.appendingPathComponent("codex").path
            ])
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func launchServer() {
        guard process?.isRunning != true else { return }
        restartWorkItem?.cancel()
        timer?.invalidate()
        timer = nil
        lineBuffer.removeAll(keepingCapacity: true)

        guard let executable = codexPath() else {
            emitError("ChatGPT desktop app not found", last: lastSuccess)
            scheduleRestart()
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.serverStopped() }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        // Drain diagnostics so a full pipe can never stall the local service.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            serverStartedAt = Date()
            lastResponseAt = nil
            serverExecutableModifiedAt = executableModificationDate(atPath: executable)
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "pet-usage-bubble",
                        "title": "Pet Usage Bubble",
                        "version": "1.0.0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.requestUsage()
                self?.installTimer()
            }
        } catch {
            emitError("Unable to start the usage service", last: lastSuccess)
            scheduleRestart()
        }
    }

    private func installTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollUsage()
        }
        timer?.tolerance = 0.15
    }

    private func pollUsage() {
        guard let process, process.isRunning else {
            launchServer()
            return
        }

        let now = Date()
        let responseBaseline = lastResponseAt ?? serverStartedAt
        if now.timeIntervalSince(responseBaseline) > 20 {
            restartServer("Usage service timed out; reconnecting")
            return
        }

        if let executable = codexPath(),
           executableModificationDate(atPath: executable) != serverExecutableModifiedAt {
            restartServer("ChatGPT updated; reconnecting")
            return
        }

        requestUsage()
    }

    private func executableModificationDate(atPath path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    private func restartServer(_ message: String) {
        timer?.invalidate()
        timer = nil
        emitError(message, last: lastSuccess)
        if let process, process.isRunning {
            process.terminate()
        } else {
            serverStopped()
        }
    }

    private func requestUsage() {
        guard process?.isRunning == true else { return }
        let id = nextID
        nextID += 1
        send(["id": id, "method": "account/rateLimits/read"])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try input?.write(contentsOf: data) }
        catch {
            emitError("Usage connection interrupted", last: lastSuccess)
            scheduleRestart()
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            parse(object)
        }
    }

    private func parse(_ object: [String: Any]) {
        if let result = object["result"] as? [String: Any],
           let rateLimits = result["rateLimits"] as? [String: Any] {
            publish(rateLimits)
            return
        }
        if object["method"] as? String == "account/rateLimits/updated",
           let params = object["params"] as? [String: Any],
           let rateLimits = params["rateLimits"] as? [String: Any] {
            publish(rateLimits)
        }
    }

    private func publish(_ payload: [String: Any]) {
        func window(_ key: String) -> LimitWindow? {
            guard let value = payload[key] as? [String: Any],
                  let used = value["usedPercent"] as? Int else { return nil }
            let duration = value["windowDurationMins"] as? Int
            let resetSeconds = value["resetsAt"] as? TimeInterval
            return LimitWindow(
                remaining: max(0, min(100, 100 - used)),
                durationMinutes: duration,
                resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
            )
        }

        let primary = window("primary")
        let secondary = window("secondary")
        let all = [primary, secondary].compactMap { $0 }
        let fiveHour = all.first { $0.durationMinutes == 300 } ?? primary
        let weekly = all.first { $0.durationMinutes == 10_080 } ?? secondary
        guard fiveHour != nil || weekly != nil else {
            emitError("No usage windows returned", last: lastSuccess)
            return
        }

        let snapshot = UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: Date(),
            plan: payload["planType"] as? String
        )
        DispatchQueue.main.async { [weak self] in
            self?.lastResponseAt = snapshot.fetchedAt
            self?.lastSuccess = snapshot.fetchedAt
            self?.onState?(.ready(snapshot))
        }
    }

    private func emitError(_ message: String, last: Date?) {
        DispatchQueue.main.async { [weak self] in self?.onState?(.error(message, last)) }
    }

    private func serverStopped() {
        process = nil
        input = nil
        timer?.invalidate()
        timer = nil
        emitError("Usage service reconnecting", last: lastSuccess)
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.launchServer() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
}

private final class UsageView: NSView {
    var state: UsageState = .loading("Connecting…") { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let body = NSRect(x: 1, y: 9, width: bounds.width - 2, height: bounds.height - 10)
        let bubble = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bounds.midX - 6, y: 10))
        tail.line(to: NSPoint(x: bounds.midX, y: 1))
        tail.line(to: NSPoint(x: bounds.midX + 6, y: 10))
        tail.close()

        context.saveGState()
        context.setShadow(offset: NSSize(width: 0, height: -3), blur: 9, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.13, alpha: 0.97).setFill()
        bubble.fill()
        tail.fill()
        context.restoreGState()

        context.saveGState()
        bubble.addClip()
        let colors = [
            NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.15, alpha: 0.98).cgColor,
            NSColor(calibratedRed: 0.095, green: 0.055, blue: 0.16, alpha: 0.98).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        }
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        switch state {
        case .loading(let text):
            drawCenteredStatus(text, color: NSColor.white.withAlphaComponent(0.8))
        case .error:
            drawCenteredStatus("Retrying…", color: .systemOrange)
        case .ready(let snapshot):
            drawMetric(snapshot.fiveHour, title: "5h", y: 38)
            drawMetric(snapshot.weekly, title: "7d", y: 15)

            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: NSRect(x: 11, y: 36, width: bounds.width - 22, height: 1), xRadius: 0.5, yRadius: 0.5).fill()

            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 11, y: bounds.maxY - 14, width: 4, height: 4)).fill()
        }
    }

    private func drawMetric(_ window: LimitWindow?, title: String, y: CGFloat) {
        let remaining = window?.remaining
        drawText(title, in: NSRect(x: 9, y: y + 2, width: 25, height: 16), font: .systemFont(ofSize: 10, weight: .semibold), color: NSColor.white.withAlphaComponent(0.56), alignment: .right)
        drawText(remaining.map { "\($0)%" } ?? "—", in: NSRect(x: 37, y: y - 1, width: 48, height: 21), font: .roundedSystemFont(ofSize: 15, weight: .bold), color: accent(for: remaining), alignment: .left)
    }

    private func accent(for remaining: Int?) -> NSColor {
        guard let remaining else { return .secondaryLabelColor }
        if remaining <= 15 { return .systemRed }
        if remaining <= 35 { return .systemOrange }
        return NSColor(calibratedRed: 0.48, green: 0.82, blue: 1.0, alpha: 1)
    }

    private func drawCenteredStatus(_ text: String, color: NSColor) {
        drawText(text, in: NSRect(x: 8, y: 29, width: bounds.width - 16, height: 18), font: .systemFont(ofSize: 10, weight: .medium), color: color, alignment: .center)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

private extension NSFont {
    static func roundedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = UsageClient()
    private var panel: NSPanel!
    private var usageView: UsageView!
    private var anchorTimer: Timer?
    private var lastPersistedPetRead = Date.distantPast
    private var cachedPersistedPetFrame: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        client.onState = { [weak self] state in
            self?.usageView.state = state
        }
        client.start()
        anchorTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.anchorBubbleToPet()
        }
        anchorTimer?.tolerance = 0.01
        if let anchorTimer { RunLoop.main.add(anchorTimer, forMode: .common) }
        anchorBubbleToPet()
    }

    func applicationWillTerminate(_ notification: Notification) {
        anchorTimer?.invalidate()
        client.stop()
    }

    private func buildPanel() {
        let size = NSSize(width: 92, height: 66)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        usageView = UsageView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = usageView
        panel.orderOut(nil)
    }

    private func anchorBubbleToPet() {
        guard let petFrame = petFrame() else {
            panel.orderOut(nil)
            return
        }
        let target = NSPoint(
            x: petFrame.midX - panel.frame.width / 2,
            y: petFrame.maxY + 4
        )
        if abs(panel.frame.origin.x - target.x) > 1 || abs(panel.frame.origin.y - target.y) > 1 {
            panel.setFrameOrigin(target)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func petFrame() -> NSRect? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
            cachedPersistedPetFrame = nil
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let primary = NSScreen.screens.first else { return nil }

        if let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard let owner = window[kCGWindowOwnerName as String] as? String,
                      owner == "ChatGPT" || owner == "Codex",
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 2,
                      (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                      ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.01,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      cgFrame.width >= 120, cgFrame.width <= 240,
                      cgFrame.height >= 120, cgFrame.height <= 260 else { continue }

                return NSRect(
                    x: cgFrame.minX,
                    y: primary.frame.maxY - cgFrame.maxY,
                    width: cgFrame.width,
                    height: cgFrame.height
                )
            }
        }

        return persistedPetFrame(primaryScreen: primary)
    }

    private func persistedPetFrame(primaryScreen: NSScreen) -> NSRect? {
        let now = Date()
        if now.timeIntervalSince(lastPersistedPetRead) < 0.25 {
            return cachedPersistedPetFrame
        }
        lastPersistedPetRead = now

        let stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["electron-avatar-overlay-open"] as? Bool == true,
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = (bounds["x"] as? NSNumber)?.doubleValue,
              let y = (bounds["y"] as? NSNumber)?.doubleValue else {
            cachedPersistedPetFrame = nil
            return nil
        }

        let mascotSize = NSSize(width: 112, height: 121)
        let frame = NSRect(
            x: x,
            y: primaryScreen.frame.maxY - y - mascotSize.height,
            width: mascotSize.width,
            height: mascotSize.height
        )
        cachedPersistedPetFrame = frame
        return frame
    }

}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
