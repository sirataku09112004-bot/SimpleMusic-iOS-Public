import SwiftUI

enum AppMenuAction { case importMusic, failures, storage, statistics, artwork, backup, deletion, playback, normalization, help, licenses, demo }

// A separate presentation keeps periodic playback updates out of the action menu.
struct AppMenuView: View {
    let ready: Bool
    let busy: Bool
    let hasTracks: Bool
    let message: String
    let hasFailures: Bool
    @ObservedObject var artwork: ArtworkModel
    let select: (AppMenuAction) -> Void
    @AppStorage("artworkFetchEnabled") private var imageNetwork = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("音楽を取り込む", systemImage: "plus.circle.fill") { select(.importMusic) }
                        .disabled(!ready || busy).accessibilityIdentifier("menu-import-music")
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if hasFailures { Button("取り込めなかったファイルを確認") { select(.failures) } }
                } footer: { Text("MP3・AAC・FLAC・WAV・Ogg Opus・Ogg Vorbisを複数選択できます。取り込んだ音楽はオフラインで再生できます。") }
                Section {
                    Button("バックアップ・復元", systemImage: "externaldrive") { select(.backup) }
                    Button("保存状況", systemImage: "internaldrive") { select(.storage) }
                    Button("再生統計", systemImage: "chart.bar") { select(.statistics) }
                    Button("再生設定", systemImage: "gearshape") { select(.playback) }
                    Button("音量正規化", systemImage: "speaker.wave.2") { select(.normalization) }
                    Button("曲をまとめて削除", systemImage: "trash") { select(.deletion) }
                        .disabled(!ready || busy || !hasTracks)
                }
                Section("曲の画像") {
                    Button("既存曲の画像を取得・再試行", systemImage: "photo") { select(.artwork) }
                        .disabled(artwork.busy || !ready || busy)
                    Toggle("画像の自動取得を許可", isOn: $imageNetwork)
                    if artwork.busy { Button("画像取得を中止") { artwork.cancel() } }
                    if !artwork.message.isEmpty { Text(artwork.message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Button("使い方・対応状況", systemImage: "info.circle") { select(.help) }
                    Button("オープンソースライセンス", systemImage: "doc.text") { select(.licenses) }
                    Button("動作確認用の音を追加", systemImage: "waveform") { select(.demo) }.disabled(!ready || busy)
                }
            }.navigationTitle("メニュー")
                .accessibilityIdentifier("app-menu-page")
                .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}

