import SwiftUI

@main
struct JigglerApp: App {
    @StateObject private var engine = JigglerEngine()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.isActive ? "cursorarrow.motionlines" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}
