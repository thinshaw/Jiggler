import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: JigglerEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !engine.isAccessibilityGranted {
                    accessibilityBanner.padding()
                    Divider()
                }

                // Status + toggle
                Group {
                    statusRow
                        .padding([.horizontal, .top])
                    toggleButton
                        .padding(.horizontal)
                        .padding(.top, 8)
                    if engine.isActive {
                        countersBlock.padding(.horizontal)
                    }
                }
                .padding(.bottom, 12)

                Divider()

                // Jiggle settings
                settingsSection

                Divider()

                // Schedule
                scheduleSection

                Divider()

                // System
                systemSection

                Divider()

                // Actions
                actionsSection
            }
        }
        .frame(width: 300, height: min(contentHeight, 640))
        .onAppear { engine.checkAccessibility() }
    }

    // Approximate height so the popover sizes itself reasonably
    private var contentHeight: CGFloat {
        var h: CGFloat = 340
        if !engine.isAccessibilityGranted { h += 90 }
        if engine.isActive { h += 44 }
        if engine.stopTimeEnabled { h += 44 }
        if engine.batteryThresholdEnabled { h += 44 }
        return h
    }

    // MARK: - Accessibility banner

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange).font(.callout.bold())
            Text("System Settings → Privacy & Security → Accessibility → enable Jiggler.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { engine.requestAccessibility() }
                .controlSize(.small)
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(engine.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(engine.isActive ? "Active" : "Inactive")
                .fontWeight(.semibold)
            Spacer()
            if engine.isActive, let method = engine.lastJiggleMethod {
                Label(method.rawValue, systemImage: method.icon)
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var toggleButton: some View {
        Button(action: engine.toggle) {
            Text(engine.isActive ? "Stop Jiggling" : "Start Jiggling")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isActive ? .red : .accentColor)
        .controlSize(.large)
    }

    private var countersBlock: some View {
        Label(
            engine.isWaitingForInputToStop ? "Waiting for input to stop" : "Next jiggle in \(engine.nextJiggleIn)s",
            systemImage: engine.isWaitingForInputToStop ? "pause.circle" : "timer"
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }

    // MARK: - Settings section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(label: "Jiggle every") {
                Text("1–4 min after input stops")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Methods — random order")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(JiggleMethod.allCases) { method in
                    Toggle(isOn: Binding(
                        get: { engine.enabledMethods.contains(method) },
                        set: { on in
                            if on { engine.enabledMethods.insert(method) }
                            else if engine.enabledMethods.count > 1 { engine.enabledMethods.remove(method) }
                        }
                    )) {
                        Label(method.rawValue, systemImage: method.icon).font(.callout)
                    }
                    .disabled(engine.isActive)
                }
            }
        }
        .padding()
    }

    // MARK: - Schedule section

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule").font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: $engine.stopTimeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deactivate at")
                    if engine.stopTimeEnabled {
                        DatePicker("", selection: $engine.stopTime,
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - System section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System").font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: $engine.batteryThresholdEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stop below battery")
                        Spacer()
                        if let level = engine.currentBatteryLevel {
                            Text("Now: \(level)%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if engine.batteryThresholdEnabled {
                        Picker("", selection: $engine.batteryThreshold) {
                            ForEach([5, 10, 15, 20, 25], id: \.self) { pct in
                                Text("\(pct)%").tag(pct)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { engine.launchAtLogin },
                set: { engine.setLaunchAtLogin($0) }
            )) {
                Text("Launch at Login")
            }
        }
        .padding()
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(spacing: 8) {
            Button("Test Mouse Move Now") { engine.testMouseMove() }
                .frame(maxWidth: .infinity)
            Button("Quit Jiggler") { NSApplication.shared.terminate(nil) }
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }
}
