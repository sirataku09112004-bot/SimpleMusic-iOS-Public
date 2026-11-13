import SwiftUI
import Foundation

struct StorageSummary: Sendable {
    var found = 0
    var missing = 0
    var legacy = 0
    var publicFiles = 0
    var logicalBytes: Int64 = 0
    var reportedAllocation: Int64 = 0
    var auxiliaryBytes: Int64 = 0
    var artworkBytes: Int64 = 0
}
enum StorageDiagnostics {
    static func inspect(tracks: [Track], directory: URL = LibraryStore.defaultDirectory) -> StorageSummary {
        var result = StorageSummary()
        let manager = FileManager.default
        for track in tracks {
            if track.storageLocation == .documentsMusic { result.publicFiles += 1 } else { result.legacy += 1 }
            let url = track.audioURL(in: directory)
            guard let values = try? url.resourceValues(forKeys:[.fileSizeKey,.totalFileAllocatedSizeKey]), let size = values.fileSize else { result.missing += 1; continue }
            result.found += 1; result.logicalBytes += Int64(size)
            result.reportedAllocation += Int64(values.totalFileAllocatedSize ?? 0)
        }
        for name in ["library.json","playback.json","loudness-v1.json"] {
            let values = try? directory.appendingPathComponent(name).resourceValues(forKeys:[.fileSizeKey])
            result.auxiliaryBytes += Int64(values?.fileSize ?? 0)
        }
        let artwork = directory.appendingPathComponent("artwork",isDirectory:true)
        for file in (try? manager.contentsOfDirectory(at:artwork,includingPropertiesForKeys:[.fileSizeKey])) ?? [] {
            result.artworkBytes += Int64((try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize ?? 0)
        }
        return result
    }
}
struct StorageDiagnosticsView: View {
    let tracks: [Track]
    @State private var summary: StorageSummary?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let summary {
                    Section("音楽の保存状況") {
                        Text("見つかった音楽: \(summary.found)曲／見つからない音楽: \(summary.missing)曲")
                        Text("音楽ファイルの合計容量: \(size(summary.logicalBytes))")
                        Text("従来の専用領域: \(summary.legacy)曲／公開Musicフォルダ: \(summary.publicFiles)曲")
                        Text("ファイルごとの割当量の合計: \(size(summary.reportedAllocation))").font(.footnote)
                        Text("コピー間で共有する領域があるため、合計容量や割当量はiPhone全体で追加消費している容量を表すものではありません。設定アプリの容量表示と一致するとは限りません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("設定とキャッシュ") {
                        Text("曲一覧・再生データ・音量解析: \(size(summary.auxiliaryBytes))")
                        Text("サムネイル: \(size(summary.artworkBytes))")
                    }
                } else { ProgressView("保存場所を確認しています…") }
                Section("ファイルアプリのSimpleMusicフォルダ") {
                    Text("今後の取り込みは「このiPhone内／SimpleMusic／Music」に保存します。従来の曲は専用領域に保持し、自動移動しません。")
                    Text("Music内のファイルをファイルアプリで削除・移動・名前変更すると一覧との対応が外れます。同じ内容を再取り込みすると曲IDとお気に入り・回数を保持して修復します。")
                    Text("SimpleMusicを削除すると専用領域・Music・Backupsも消えます。音楽の原本とバックアップは別の保存先にも保管してください。")
                }.font(.footnote)
            }.navigationTitle("保存状況").toolbar { Button("閉じる") { dismiss() } }
                .task {
                    let audioTracks = tracks
                    summary = await Task.detached(priority:.utility) { StorageDiagnostics.inspect(tracks:audioTracks) }.value
                }
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
}
