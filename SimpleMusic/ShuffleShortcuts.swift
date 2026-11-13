import AppIntents

@available(iOS 18.0, *)
struct ShuffleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ControlShuffleIntent(), phrases: ["\(.applicationName)でシャッフル再生"],
            shortTitle: "シャッフル再生", systemImageName: "shuffle")
    }
}
