import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= 8 * 1024 * 1024 else { throw BackupError.tooLarge }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var preferences: PlaybackPreferences
    @ObservedObject var player: MusicPlayer
    @ObservedObject var normalization: NormalizationModel
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var document = BackupDocument()
    @State private var preview: BackupEnvelope?
    @State private var confirming = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("バックアップを保存") {
                        do {
                            player.refresh()
                            player.checkpoint()
                            document = BackupDocument(data: try BackupCodec.make(tracks: library.tracks, state: preferences.state).encoded())
                            exporting = true
                        } catch { message = error.localizedDescription }
                    }.disabled(busy || library.busy || !library.ready || !preferences.ready)
                    Button("バックアップから復元") { importing = true }
                        .disabled(busy || library.busy || !library.ready || !preferences.ready)
                    if busy { ProgressView("内容を確認しています…") }
                    if !message.isEmpty { Text(message).font(.footnote) }
                } header: { Text("バックアップ") } footer: {
                    Text("お気に入り・回数・設定・キュー・再生位置を保存します。音楽本体と画像は含みません。音量解析のキャッシュは再作成できます。")
                }
                Section("保存先について") {
                    Text("保存画面で「このiPhone内」、iCloud Drive、他のファイルアプリなどを選べます。クラウドは必須ではありません。")
                    Text("SimpleMusic内（Backupsを含む）のバックアップは、SimpleMusicを削除すると消えます。再インストールに備える場合は別の保存先を選んでください。")
                    Text("Kingboxなど他のアプリ内に保存したものは、そのアプリを削除すると失われる可能性があります。「このiPhone内」の全フォルダがアプリ削除から独立しているとは保証できません。")
                }.font(.footnote)
                if let pending = preferences.state.pendingRestore, pending.remaining > 0 {
                    Section("復元待ち") {
                        Text("未取り込みの\(pending.remaining)曲の情報を保管しています。同じ内容の音楽を取り込むと自動で紐付きます。名前や保存場所は変わっていても構いません。")
                    }
                }
                if let backup = preview {
                    Section("復元内容の確認") {
                        Text("保存日時: \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("\(backup.songs.count)曲・お気に入り\(backup.songs.filter(\.favorite).count)曲")
                        let hashes = Set(library.tracks.map(\.sha256))
                        let matched = backup.songs.filter { hashes.contains($0.hash) }.count
                        Text("今ある音楽と一致: \(matched)曲／取り込み待ち: \(backup.songs.count - matched)曲")
                        Text("現在の設定・再生データをこの内容に置き換えます。音楽ファイルは削除・移動しません。再生は一時停止します。")
                        Button("この内容で置き換える", role: .destructive) { confirming = true }
                            .disabled(library.busy || busy)
                        Button("復元をキャンセル") { preview = nil }
                    }
                }
            }.navigationTitle("バックアップ・復元")
                .toolbar { Button("閉じる") { dismiss() } }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                    defaultFilename: "SimpleMusic-backup-\(Date().formatted(.iso8601.year().month().day()))") { result in
                    switch result {
                    case .success: message = "バックアップを保存しました。音楽本体は別途保管してください。"
                    case .failure(let error): message = "保存できません: \(error.localizedDescription)"
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url):
                        busy = true; preview = nil
                        Task {
                            defer { busy = false }
                            do { preview = try await BackupReader().read(url); message = "内容を確認してから復元してください。" }
                            catch { message = error.localizedDescription }
                        }
                    case .failure(let error): message = error.localizedDescription
                    }
                }
                .confirmationDialog("現在の設定と再生データを置き換えますか？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("置き換えて復元", role: .destructive) { restore() }
                    Button("キャンセル", role: .cancel) {}
                } message: { Text("既存の音楽は保持します。今の設定を残したい場合は先にバックアップしてください。") }
        }
    }
    private func restore() {
        guard let backup = preview, library.ready, !library.busy else { return }
        do {
            let candidate = try BackupCodec.restored(backup, tracks: library.tracks)
            try preferences.replaceState(candidate)
            player.adoptRestoredState(from: library.tracks, pause: true)
            try preferences.applyRestoredSettings(normalization: normalization)
            player.updateNormalization()
            preview = nil; message = "復元しました。未取り込みの曲の情報も保持します。"
        } catch { message = error.localizedDescription }
    }
}

