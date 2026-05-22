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
    @Published var isWaitingForInputToStop = false

    // MARK: - Persisted settings
    @Published var enabledMethods: Set<JiggleMethod> = [.mouseMove, .scroll, .keyPress] {
        didSet { UserDefaults.standard.set(enabledMethods.map(\.rawValue), forKey: "enabledMethods") }
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
    private var maintenanceTimer: Timer?
    private var activityMonitor: Any?
    private var shuffledDeck: [JiggleMethod] = []
    private var deckIndex = 0
    private var moveGeneration = 0
    private var nextJiggleAt: Date?
    private var lastBatteryCheckAt: Date = .distantPast
    private var lastUserInputAt: Date = Date()
    private var ignoreMouseMovedUntil: Date = .distantPast
    private let syntheticMarker: Int64 = 0x4A494747  // "JIGG"
    private let maintenanceInterval: TimeInterval = 5
    private let batteryCheckInterval: TimeInterval = 60
    private let inputSettleDelay: TimeInterval = 5
    private let mousePathPointCount = 10
    private let mousePathCoverage: CGFloat = 0.5
    private let mousePathStepDelay: TimeInterval = 0.12
    private let mousePathMargin: CGFloat = 20

    // MARK: - Init

    init() {
        isAccessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loadSettings()
    }

    private func loadSettings() {
        let ud = UserDefaults.standard
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
        performMouseMove(pointCount: mousePathPointCount, stepDelay: mousePathStepDelay)
    }

    private func start() {
        guard !enabledMethods.isEmpty else { return }
        isActive = true
        lastUserInputAt = Date()
        waitForInputToStop()
        lastBatteryCheckAt = Date()
        currentBatteryLevel = batteryThresholdEnabled ? batteryPercent() : nil

        activityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .scrollWheel, .keyDown, .flagsChanged]
        ) { [weak self] event in
            self?.handleUserInput(event)
        }

        startMaintenanceTimer()
    }

    private func scheduleNextJiggle(from date: Date = Date()) {
        let interval = Int.random(in: 60...240)
        isWaitingForInputToStop = false
        nextJiggleAt = date.addingTimeInterval(TimeInterval(interval))
        nextJiggleIn = interval
    }

    private func waitForInputToStop() {
        isWaitingForInputToStop = true
        nextJiggleAt = nil
        nextJiggleIn = 0
    }

    private func startMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: maintenanceInterval, repeats: true) { [weak self] _ in
            self?.maintenanceTick()
        }
        timer.tolerance = maintenanceInterval / 2
        maintenanceTimer = timer
        maintenanceTick()
    }

    private func maintenanceTick() {
        let now = Date()

        if isWaitingForInputToStop {
            let inputSettleAt = lastUserInputAt.addingTimeInterval(inputSettleDelay)
            if now >= inputSettleAt {
                scheduleNextJiggle(from: now)
            }
        } else if let nextJiggleAt {
            nextJiggleIn = max(0, Int(ceil(nextJiggleAt.timeIntervalSince(now))))
            if now >= nextJiggleAt {
                jiggle()
                scheduleNextJiggle(from: now)
            }
        } else {
            scheduleNextJiggle(from: now)
        }

        // Auto-stop: stop time reached
        if stopTimeEnabled {
            let cal = Calendar.current
            let current = cal.dateComponents([.hour, .minute], from: now)
            let stopComponents = cal.dateComponents([.hour, .minute], from: stopTime)
            if current.hour == stopComponents.hour && current.minute == stopComponents.minute {
                stop()
                return
            }
        }

        // Shelling out is relatively expensive, so only sample battery occasionally.
        if batteryThresholdEnabled &&
            (currentBatteryLevel == nil || now.timeIntervalSince(lastBatteryCheckAt) >= batteryCheckInterval) {
            lastBatteryCheckAt = now
            let level = batteryPercent()
            currentBatteryLevel = level
            if let level, level <= batteryThreshold {
                stop()
            }
        }
    }

    func stop() {
        isActive = false
        moveGeneration += 1
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        if let m = activityMonitor { NSEvent.removeMonitor(m); activityMonitor = nil }
        nextJiggleIn = 0
        nextJiggleAt = nil
        lastJiggleMethod = nil
        isWaitingForInputToStop = false
    }

    private func handleUserInput(_ event: NSEvent) {
        if let cg = event.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            if event.type == .mouseMoved && Date() < self.ignoreMouseMovedUntil { return }
            self.lastUserInputAt = Date()
            if self.nextJiggleAt != nil || !self.isWaitingForInputToStop {
                self.moveGeneration += 1
                self.waitForInputToStop()
            }
        }
    }

    // MARK: - Jiggle dispatch

    private func jiggle() {
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
        ignoreMouseMovedUntil = Date().addingTimeInterval(0.25)
        CGWarpMouseCursorPosition(point)
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event?.post(tap: .cghidEventTap)
    }

    private func performMouseMove() {
        performMouseMove(pointCount: mousePathPointCount, stepDelay: mousePathStepDelay)
    }

    private func performMouseMove(pointCount: Int, stepDelay: TimeInterval) {
        guard let startCG = CGEvent(source: nil)?.location else { return }

        let bounds = displayBounds(containing: startCG)
        let insetBounds = bounds.insetBy(dx: mousePathMargin, dy: mousePathMargin)
        let pathBounds = pathBounds(around: startCG, in: insetBounds, coverage: mousePathCoverage)

        moveGeneration += 1
        let gen = moveGeneration

        let targets = randomMousePath(pointCount: pointCount, in: pathBounds, returningTo: startCG)

        for (i, target) in targets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stepDelay) { [weak self] in
                guard let self, self.moveGeneration == gen else { return }
                self.moveCursor(to: target)
            }
        }
    }

    private func randomMousePath(pointCount: Int, in bounds: CGRect, returningTo start: CGPoint) -> [CGPoint] {
        var targets = (0..<pointCount).map { _ in
            CGPoint(
                x: CGFloat.random(in: bounds.minX...bounds.maxX),
                y: CGFloat.random(in: bounds.minY...bounds.maxY)
            )
        }
        targets.append(start)
        return targets
    }

    private func pathBounds(around point: CGPoint, in bounds: CGRect, coverage: CGFloat) -> CGRect {
        let width = max(1, bounds.width * coverage)
        let height = max(1, bounds.height * coverage)
        let x = max(bounds.minX, min(bounds.maxX - width, point.x - width / 2))
        let y = max(bounds.minY, min(bounds.maxY - height, point.y - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayBounds(containing point: CGPoint) -> CGRect {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, 1, &display, &count)
        if result == .success, count > 0 {
            return CGDisplayBounds(display)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: - Scroll & key press

    private func performScroll() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let up = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 120, wheel2: 0, wheel3: 0)
            up?.setIntegerValueField(.eventSourceUserData, value: self.syntheticMarker)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func performKeyPress() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: true)
        down?.flags = []
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
        up?.flags = []
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
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
