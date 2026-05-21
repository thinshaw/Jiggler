import Foundation
import CoreGraphics
import AppKit
import ServiceManagement

enum JiggleMethod: String, CaseIterable, Identifiable {
    case mouseMove = "Mouse Move"
    case scroll = "Scroll"
    case keyPress = "Key Press"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mouseMove: return "cursorarrow.motionlines"
        case .scroll:    return "arrow.up.and.down"
        case .keyPress:  return "keyboard"
        }
    }
}

class JigglerEngine: ObservableObject {
    // MARK: - Core state
    @Published var isActive = false
    @Published var isAccessibilityGranted = false
    @Published var nextJiggleIn: Int = 0
    @Published var lastJiggleMethod: JiggleMethod?
    @Published var mouseIdleSeconds: Int = 0

    // MARK: - Persisted settings
    @Published var enabledMethods: Set<JiggleMethod> = [.mouseMove, .scroll, .keyPress] {
        didSet { UserDefaults.standard.set(enabledMethods.map(\.rawValue), forKey: "enabledMethods") }
    }
    @Published var idleThresholdSeconds: Int = 120 {
        didSet { UserDefaults.standard.set(idleThresholdSeconds, forKey: "idleThresholdSeconds") }
    }

    // Stop time
    @Published var stopTimeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(stopTimeEnabled, forKey: "stopTimeEnabled") }
    }
    @Published var stopTime: Date = defaultStopTime() {
        didSet { UserDefaults.standard.set(stopTime, forKey: "stopTime") }
    }

    // Battery threshold
    @Published var batteryThresholdEnabled: Bool = false {
        didSet { UserDefaults.standard.set(batteryThresholdEnabled, forKey: "batteryThresholdEnabled") }
    }
    @Published var batteryThreshold: Int = 10 {
        didSet { UserDefaults.standard.set(batteryThreshold, forKey: "batteryThreshold") }
    }
    @Published var currentBatteryLevel: Int? = nil

    // Launch at login (driven by SMAppService, not UserDefaults)
    @Published var launchAtLogin: Bool = false

    // MARK: - Private
    private var jiggleTimer: Timer?
    private var countdownTimer: Timer?
    private var moveMonitor: Any?
    private var activityMonitor: Any?
    private var shuffledDeck: [JiggleMethod] = []
    private var deckIndex = 0
    private var moveGeneration = 0
    private var lastHardwareMoveAt: Date = Date()
    private let syntheticMarker: Int64 = 0x4A494747  // "JIGG"

    // MARK: - Init

    init() {
        isAccessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loadSettings()
    }

    private func loadSettings() {
        let ud = UserDefaults.standard
        if let v = ud.object(forKey: "idleThresholdSeconds")  as? Int  { idleThresholdSeconds = v }
        if let v = ud.object(forKey: "stopTimeEnabled")       as? Bool { stopTimeEnabled = v }
        if let v = ud.object(forKey: "stopTime")              as? Date { stopTime = v }
        if let v = ud.object(forKey: "batteryThresholdEnabled") as? Bool { batteryThresholdEnabled = v }
        if let v = ud.object(forKey: "batteryThreshold")      as? Int  { batteryThreshold = v }
        if let names = ud.object(forKey: "enabledMethods") as? [String] {
            let loaded = Set(names.compactMap { JiggleMethod(rawValue: $0) })
            if !loaded.isEmpty { enabledMethods = loaded }
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.isAccessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            } catch {
                launchAtLogin = false
            }
        } else {
            try? SMAppService.mainApp.unregister()
            launchAtLogin = false
        }
    }

    // MARK: - Start / stop

    func toggle() {
        isActive ? stop() : start()
    }

    func testMouseMove() {
        performMouseMove()
    }

    private func start() {
        guard !enabledMethods.isEmpty else { return }
        isActive = true
        lastHardwareMoveAt = Date()
        mouseIdleSeconds = 0
        scheduleNext()
        currentBatteryLevel = batteryPercent()

        activityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            if event.type == .mouseMoved,
               let cg = event.cgEvent,
               cg.getIntegerValueField(.eventSourceUserData) == self.syntheticMarker { return }
            self.lastHardwareMoveAt = Date()
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.nextJiggleIn > 0 { self.nextJiggleIn -= 1 }
            self.mouseIdleSeconds = Int(Date().timeIntervalSince(self.lastHardwareMoveAt))

            // Auto-stop: stop time reached
            if self.stopTimeEnabled {
                let cal = Calendar.current
                let now  = cal.dateComponents([.hour, .minute], from: Date())
                let stop = cal.dateComponents([.hour, .minute], from: self.stopTime)
                if now.hour == stop.hour && now.minute == stop.minute {
                    self.stop()
                    return
                }
            }

            // Auto-stop: battery below threshold (check every 30 s)
            if self.batteryThresholdEnabled && Int(Date().timeIntervalSince1970) % 30 == 0 {
                let level = self.batteryPercent()
                self.currentBatteryLevel = level
                if let level, level <= self.batteryThreshold {
                    self.stop()
                }
            }
        }
    }

    private func scheduleNext() {
        jiggleTimer?.invalidate()
        let interval = Int.random(in: 60...240)
        nextJiggleIn = interval
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.jiggle()
            self.scheduleNext()
        }
    }

    func stop() {
        isActive = false
        moveGeneration += 1
        jiggleTimer?.invalidate()
        jiggleTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        removeMoveMonitor()
        if let m = activityMonitor { NSEvent.removeMonitor(m); activityMonitor = nil }
        nextJiggleIn = 0
        mouseIdleSeconds = 0
        lastJiggleMethod = nil
    }

    private func removeMoveMonitor() {
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
    }

    // MARK: - Jiggle dispatch

    private func jiggle() {
        guard mouseIdleSeconds >= idleThresholdSeconds else { return }

        let enabled = Array(enabledMethods)
        guard !enabled.isEmpty else { return }

        if deckIndex >= shuffledDeck.count || !shuffledDeck.allSatisfy({ enabledMethods.contains($0) }) {
            shuffledDeck = enabled.shuffled()
            deckIndex = 0
        }

        let method = shuffledDeck[deckIndex]
        deckIndex += 1
        lastJiggleMethod = method

        switch method {
        case .mouseMove: performMouseMove()
        case .scroll:    performScroll()
        case .keyPress:  performKeyPress()
        }
    }

    // MARK: - Mouse move animation

    private func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event?.post(tap: .cghidEventTap)
    }

    private func performMouseMove() {
        guard let screen = NSScreen.main else { return }

        let ns = NSEvent.mouseLocation
        let startCG = CGPoint(x: ns.x, y: screen.frame.height - ns.y)
        let amplitude: CGFloat = 150
        let margin: CGFloat = 20
        let W = screen.frame.width
        let H = screen.frame.height

        moveGeneration += 1
        let gen = moveGeneration

        removeMoveMonitor()
        var userTookOver = false
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return }
            if let cg = event.cgEvent,
               cg.getIntegerValueField(.eventSourceUserData) == self.syntheticMarker { return }
            userTookOver = true
        }

        var targets: [CGPoint] = []
        for n in 0..<20 {
            let t  = CGFloat(n) / 19.0 * 2 * .pi
            let dx = amplitude * sin(t * 3)           + CGFloat.random(in: -3...3)
            let dy = amplitude * sin(t * 2 + .pi / 4) + CGFloat.random(in: -3...3)
            targets.append(CGPoint(
                x: max(margin, min(W - margin, startCG.x + dx)),
                y: max(margin, min(H - margin, startCG.y + dy))
            ))
        }
        targets.append(startCG)

        for (i, target) in targets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak self] in
                guard let self, self.moveGeneration == gen else { return }
                if userTookOver {
                    self.moveGeneration += 1
                    self.removeMoveMonitor()
                    return
                }
                self.moveCursor(to: target)
                if i == targets.count - 1 { self.removeMoveMonitor() }
            }
        }
    }

    // MARK: - Scroll & key press

    private func performScroll() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 120, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        }
    }

    private func performKeyPress() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: true)
        down?.flags = []
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Battery

    private func batteryPercent() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "batt"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let range = output.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) else { return nil }
        return Int(String(output[range]).dropLast())
    }
}

// MARK: - Helpers

private func defaultStopTime() -> Date {
    Calendar.current.date(from: DateComponents(hour: 17, minute: 0)) ?? Date()
}
