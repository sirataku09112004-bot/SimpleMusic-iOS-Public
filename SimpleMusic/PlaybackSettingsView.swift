import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var player: MusicPlayer
    @AppStorage(PlaybackRecovery.mixKey) private var mixAudio = true
    @Environment(\.dismiss) private var dismiss
    @State private var routeMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("他のアプリと音声を同時再生", isOn: $mixAudio)
                } footer: {
                    Text("動画や広告のほか、他の音楽アプリとも音声が重なることがあります。ロック画面やイヤホンから操作しづらい場合はオフにしてください。")
                }
                Section {
                    if let car = player.carAudioRoute {
                        LabeledContent("登録済み", value: car.name)
                        Button("車の登録を解除", role: .destructive) {
                            player.removeCarAudioRoute()
                            routeMessage = ""
                        }
                    }
                    Button("現在の出力先を車として登録") {
                        routeMessage = player.registerCarAudioRoute()
                            ? "車の音声出力を登録しました。"
                            : "車でSimpleMusicを再生し、出力先が車になってから登録してください。"
                    }
                    if !routeMessage.isEmpty { Text(routeMessage).font(.footnote) }
                } header: {
                    Text("車のBluetooth再接続")
                } footer: {
                    Text("車で再生したまま切断したときだけ、同じ出力先で続きから再開します。ショートカットのBluetoothオートメーションには simplemusic://resume を設定できます。")
                }
            }
            .navigationTitle("再生設定")
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
