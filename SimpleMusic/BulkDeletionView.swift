import SwiftUI

struct BulkDeletionView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmedIDs = Set<UUID>()
    @State private var result = ""
    @State private var filtered: [Track] = []
    @State private var filteredIDs = Set<UUID>()
    private func updateFiltered() {
        filtered = LibraryQuery.apply(library.tracks, search: search, favoritesOnly: false,
            favorites: [], counts: [:], sort: .addedOldest)
        filteredIDs = Set(filtered.map(\.id))
    }
    private var allVisibleSelected: Bool { !filteredIDs.isEmpty && filteredIDs.isSubset(of: selected) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(allVisibleSelected ? "選択を解除" : (search.isEmpty ? "すべて選択" : "検索結果をすべて選択")) {
                        if allVisibleSelected { selected.subtract(filteredIDs) }
                        else { selected.formUnion(filteredIDs) }
                    }.disabled(library.busy || filteredIDs.isEmpty)
                        .accessibilityIdentifier("bulk-select-all")
                    Text("選択中 \(selected.count)曲 / 全\(library.tracks.count)曲")
                        .accessibilityIdentifier("bulk-selection-count")
                    if !result.isEmpty { Text(result).font(.footnote) }
                } footer: {
                    Text("曲を選んで下の削除ボタンを押してください。アプリ内のコピーを削除し、元の音楽ファイルは残します。検索を変えても選択した曲は保持します。")
                }
                Section {
                    ForEach(filtered) { track in
                        Button {
                            if selected.contains(track.id) { selected.remove(track.id) }
                            else { selected.insert(track.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(track.artistLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.disabled(library.busy)
                            .accessibilityLabel("\(track.title)を選択")
                            .accessibilityValue(selected.contains(track.id) ? "選択済み" : "未選択")
                            .accessibilityIdentifier("bulk-row-\(track.title)")
                    }
                }
            }
            .navigationTitle("曲をまとめて削除")
            .searchable(text: $search, prompt: "曲名・アーティストを検索")
            .toolbar { Button("閉じる") { dismiss() }.disabled(library.busy) }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    if library.busy { ProgressView("削除しています…") }
                    Button("選択した\(selected.count)曲を削除", role: .destructive) {
                        confirmedIDs = selected
                        confirming = true
                    }.buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || library.busy)
                        .accessibilityIdentifier("bulk-delete-selected")
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .confirmationDialog("\(confirmedIDs.count)曲をアプリから削除しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("\(confirmedIDs.count)曲を削除", role: .destructive) {
                    let ids = confirmedIDs
                    Task {
                        let deleted = await library.deleteMany(ids, player: player)
                        selected.subtract(deleted)
                        result = library.message
                    }
                }.accessibilityIdentifier("bulk-confirm-delete")
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("選択した曲のアプリ内コピー、お気に入り、再生回数、キューからの参照を削除します。元ファイルは残ります。選択した曲が再生中なら停止します。")
            }
            .interactiveDismissDisabled(library.busy)
            .onAppear { updateFiltered() }
            .onChange(of: search) { _, _ in updateFiltered() }
            .onChange(of: library.tracks) { _, tracks in
                selected.formIntersection(Set(tracks.map(\.id))); updateFiltered()
            }
        }
    }
}
