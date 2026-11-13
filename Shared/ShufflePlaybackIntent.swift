import AppIntents
import OSLog

@available(iOS 18.0, *)
struct ShufflePlaybackIntent: OpenIntent {
    static var title: LocalizedStringResource = "SimpleMusic シャッフル再生"
    static var description = IntentDescription("SimpleMusicを開き、現在のキュー（空なら全曲）を少ない再生回数を優先してシャッフル再生します。")
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    // This action touches the app-owned player request, so the extension must
    // not be considered an execution target even though it carries this type.
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "開く機能")
    var target: ShuffleDestination

    init() { target = .shuffle }
    @MainActor
    func perform() async throws -> some IntentResult {
        try enqueueInApp()
        return .result()
    }
    @MainActor
    private func enqueueInApp() throws {
        // OpenIntent explicitly asks Control Center to foreground the containing app.
        // Keep this intent and its target enum in both app and extension targets.
        // Do not create an audio engine in the widget's sandbox.
        #if CONTROL_EXTENSION
        Logger(subsystem: "com.sirataku.simplemusic", category: "ControlLaunch")
            .error("Foreground shuffle intent unexpectedly executed in extension")
        throw ControlLaunchError.appRequired
        #else
        ControlRequests.shared.recordAppIntent()
        ControlRequests.shared.submit()
        #endif
    }
}

@available(iOS 18.0, *)
enum ShuffleDestination: String, AppEnum {
    case shuffle
    static var typeDisplayRepresentation = TypeDisplayRepresentation("SimpleMusicの機能")
    static var caseDisplayRepresentations: [ShuffleDestination: DisplayRepresentation] = [
        .shuffle: DisplayRepresentation("シャッフル再生")
    ]
}

enum ControlLaunchError: LocalizedError {
    case appRequired
    var errorDescription: String? { "SimpleMusicを開いて再生してください。拡張機能の署名とインストールを確認してください。" }
}
