import SwiftUI
import AppIntents
import WidgetKit

@main
struct SimpleMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var registeredAfterActivation = false
    init() {
        if #available(iOS 18.0, *) {
            // Register the extracted actions with iOS before a control needs to
            // serialize its OpenIntent. Refresh installed control templates too.
            ShuffleShortcuts.updateAppShortcutParameters()
            ControlCenter.shared.reloadAllControls()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active, !registeredAfterActivation else { return }
                    registeredAfterActivation = true
                    if #available(iOS 18.0, *) {
                        // Launch-time registration can precede Launch Services
                        // readiness. Retry once when the real app is active.
                        ShuffleShortcuts.updateAppShortcutParameters()
                        ControlCenter.shared.reloadAllControls()
                    }
                }
        }
    }
}

