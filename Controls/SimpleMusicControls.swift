import SwiftUI
import WidgetKit
import AppIntents

@main
struct SimpleMusicControlsBundle: WidgetBundle {
    var body: some Widget { ShuffleControl() }
}

struct ShuffleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.sirataku.simplemusic.shuffle") {
            ControlWidgetButton(action: ControlShuffleIntent()) {
                Label("SimpleMusic シャッフル再生", systemImage: "shuffle")
            }
        }
        .displayName("SimpleMusic シャッフル再生")
        .description("アプリを開いて重み付きシャッフル再生を開始します。")
    }
}
