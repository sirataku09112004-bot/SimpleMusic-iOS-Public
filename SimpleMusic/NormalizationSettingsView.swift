import SwiftUI

struct NormalizationSettingsView: View {
    @ObservedObject var normalization: NormalizationModel
    let tracks: [Track]
    let busy: Bool
    let onToggle: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
                NavigationStack {
                    Form {
                        Section {
                            Toggle("曲ごとの音量をそろえる", isOn: Binding(get: { normalization.enabled }, set: {
                                normalization.setEnabled($0); onToggle()
                            })).accessibilityIdentifier("normalization-toggle")
                            Text("解析済みの曲を補正します。小さい音の増幅は最大12dB、ピークに余裕を残し、元のファイルは変更しません。聴感上の差を完全に一致させるものではありません。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section {
                            Text("解析済み \(tracks.filter { normalization.hasProfile($0) }.count) / \(tracks.count)曲")
                            if normalization.analyzing {
                                ProgressView(value: Double(normalization.completed), total: Double(max(1, normalization.total)))
                                Button("解析を中止") { normalization.cancelAnalysis() }
                            } else {
                                Button("未解析の曲を解析") { normalization.analyze(tracks) }
                                    .disabled(tracks.isEmpty || busy)
                                    .accessibilityIdentifier("analyze-loudness")
                            }
                            if !normalization.message.isEmpty { Text(normalization.message).font(.footnote) }
                        } header: {
                            Text("音楽の解析")
                        } footer: {
                            Text("解析時は曲全体を少量ずつ読みます。曲数によって時間がかかるため、充電中の実行がおすすめです。他のアプリへ移動すると解析を中止し、完了した結果は保存します。未解析の曲は元の音量で再生します。")
                        }
                    }.navigationTitle("音量正規化")
                        .toolbar { Button("閉じる") { dismiss() } }
                }
    }
}
