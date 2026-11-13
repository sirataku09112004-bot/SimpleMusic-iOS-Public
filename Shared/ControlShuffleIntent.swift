import AppIntents
import OSLog

/// A control is an audio action, not a background widget action that opens
/// another intent. Keep the definition in both targets so iOS can serialize it,
/// but execute it only in the containing app, which owns the playback engine.
@available(iOS 18.0, *)
struct ControlShuffleIntent: AppIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "SimpleMusic シャッフル再生"
    static var description = IntentDescription("SimpleMusicを開いて、既存のキューを重み付きシャッフル再生します。")
    static var isDiscoverable: Bool = true
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if CONTROL_EXTENSION
        Logger(subsystem: "com.sirataku.simplemusic", category: "ControlLaunch")
            .error("Audio shuffle action unexpectedly executed in extension")
        throw ControlLaunchError.appRequired
        #else
        Logger(subsystem: "com.sirataku.simplemusic", category: "ControlLaunch")
            .notice("Audio shuffle action received in main app")
        ControlRequests.shared.recordAppIntent()
        ControlRequests.shared.submit()
        #endif
        return .result()
    }
}
