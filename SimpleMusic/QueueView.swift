import SwiftUI

struct QueueView: View {
    @ObservedObject var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if player.queue.isEmpty {
                        ContentUnavailableView("キューは空です", systemImage: "list.bullet",
                            description: Text("曲一覧の＋から曲を追加してください。"))
                    }
                    ForEach(player.queue) { track in
                        HStack {
                            if !editing {
                                Button { player.playFromQueue(track) } label: { rowLabel(track) }
                                    .accessibilityIdentifier("queue-play-\(track.title)")
                            } else {
                                rowLabel(track)
                                let index = player.queue.firstIndex(of: track) ?? 0
                                Button {
                                    player.moveQueue(from: IndexSet(integer: index), to: index - 1)
                                } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel("\(track.title)を上へ")
                                .accessibilityIdentifier("queue-up-\(track.title)")
                                Button {
                                    player.moveQueue(from: IndexSet(integer: index), to: index + 2)
                                } label: { Image(systemName: "arrow.down") }
                                .disabled(index + 1 == player.queue.count).accessibilityLabel("\(track.title)を下へ")
                                .accessibilityIdentifier("queue-down-\(track.title)")
                                Button(role: .destructive) {
                                    player.removeQueue(at: IndexSet(integer: index))
                                } label: { Image(systemName: "trash") }
                                .disabled(player.current?.id == track.id).accessibilityLabel("\(track.title)をキューから外す")
                                .accessibilityIdentifier("queue-remove-\(track.title)")
                            }
                        }.buttonStyle(.borderless)
                    }
                } footer: {
                    Text(editing ? "矢印で順番を変更し、ごみ箱でキューから外します。選択中の曲は削除できません。" : "「編集」で順番変更・削除。曲名を押すとその曲から再生します。")
                }
                Section {
                    Picker("リピート", selection: Binding(get: { player.repeatMode }, set: { player.setRepeatMode($0) })) {
                        ForEach(RepeatMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("優先シャッフルを繰り返す", isOn: Binding(
                        get: { player.priorityLoop }, set: { player.setPriorityLoop($0) }))
                        .disabled(player.queue.isEmpty || editing)
                        .accessibilityIdentifier("queue-repeat")
                    Button("これから再生する曲を優先シャッフル", systemImage: "shuffle") {
                        player.shuffleUpcoming()
                    }.disabled(editing || player.queue.isEmpty || (player.current != nil && !player.canNext))
                    Button(role: .destructive) {
                        player.clearUpcoming()
                    } label: {
                        Label("これから再生する曲をキューから外す", systemImage: "text.badge.minus")
                    }.disabled(editing || player.queue.isEmpty || (player.current != nil && !player.canNext))
                } footer: {
                    Text("繰り返し中は最後の曲の後に、最新の再生回数でキュー全体を再シャッフルします。キューから外した曲は戻りません。")
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle("再生キュー \(player.queue.count)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "完了" : "編集") { editing.toggle() }
                        .accessibilityIdentifier("queue-edit")
                }
            }
        }
    }

    private func rowLabel(_ track: Track) -> some View {
                            HStack {
                                Image(systemName: player.current?.id == track.id ? "speaker.wave.2.fill" : "music.note")
                                    .frame(width: 24)
                                Text(track.title).lineLimit(2).foregroundStyle(.primary)
                                Spacer()
                                Text(clockText(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
    }
}
