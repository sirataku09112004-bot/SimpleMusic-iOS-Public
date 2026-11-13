import SwiftUI
import Foundation

// Actual media progress bounded by elapsed monotonic time. Reset at every seek/track transition.
struct ListeningMeter {
    private var time: Double?
    private var position: Double = 0
    private var playing = false
    private var credited: Double = 0
    mutating func reset(position: Double, time: Double, playing: Bool) {
        self.position = position; self.time = time; self.playing = playing
        credited = 0
    }
    mutating func sample(position: Double, time: Double, playing: Bool) -> Double {
        guard let old = self.time, self.playing, position.isFinite, time.isFinite,
              time >= old, position >= self.position else {
            reset(position: position, time: time, playing: playing)
            return 0
        }
        // Bound total progress since the last seek/resume, rather than each
        // timer interval. Audio render clocks advance in blocks; taking the
        // minimum per interval permanently loses valid playback on jitter.
        let total = max(0, min(time - old, position - self.position))
        let delta = max(0, total - credited)
        credited = max(credited, total)
        if !playing { reset(position: position, time: time, playing: false) }
        return delta
    }
    static func countThreshold(duration: Double) -> Double { min(10, max(0, duration)) }
    static func shouldCount(listened: Double, duration: Double, completed: Bool) -> Bool {
        guard duration.isFinite, duration > 0, listened.isFinite, listened > 0 else { return false }
        if duration >= 10 { return listened >= 10 }
        // Completion must come from the audio backend, never from a slider position.
        // Allow only a small sampling/decoder rounding error at the natural endpoint.
        return completed && listened >= duration - min(0.05, duration * 0.01)
    }
}
struct ArtistStatistic: Identifiable {
    let name: String
    var count = 0
    var seconds: Double = 0
    var id: String { name }
}
enum StatisticsQuery {
    static func artists(songs: [BackupSong]) -> [ArtistStatistic] {
        var groups: [String:ArtistStatistic] = [:]
        for song in songs {
            let name = ArtistMetadata.cleaned(song.artist) ?? "不明なアーティスト"
            var group = groups[name] ?? ArtistStatistic(name:name)
            group.count = group.count > Int.max - song.count ? Int.max : group.count + song.count
            group.seconds += song.listeningSeconds; groups[name] = group
        }
        return Array(groups.values)
    }
    static func artists(tracks: [Track], state: PlaybackState) -> [ArtistStatistic] {
        var groups: [String:ArtistStatistic] = [:]
        for track in tracks {
            let name = track.artistLabel
            var group = groups[name] ?? ArtistStatistic(name: name)
            let count = state.playCounts[track.id] ?? 0
            group.count = group.count > Int.max - count ? Int.max : group.count + count
            group.seconds += state.listeningSeconds[track.id] ?? 0
            groups[name] = group
        }
        return Array(groups.values)
    }
    static func timeText(_ seconds: Double) -> String {
        let value = Int(min(max(seconds,0), 1e12))
        return "\(value / 3600)時間\((value / 60) % 60)分\(value % 60)秒"
    }
}
struct StatisticsView: View {
    let tracks: [Track]
    @ObservedObject var preferences: PlaybackPreferences
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let songs = BackupCodec.make(tracks:tracks,state:preferences.state).songs
        let artists = StatisticsQuery.artists(songs:songs)
        return NavigationStack {
            List {
                Section("累計再生時間") {
                    Text(StatisticsQuery.timeText(songs.reduce(0) { $0 + $1.listeningSeconds }))
                    if let date = preferences.state.statisticsSince {
                        Text("\(date.formatted(date: .abbreviated, time: .omitted))以降の実測値です。過去の時間は推測していません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("実際に10秒以上聴くと1回として数えます。10秒未満の曲は最後まで再生した場合に数えます。シークで飛ばした時間は含めず、従来の再生回数は引き継ぎます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("再生回数 上位10曲") {
                    ForEach(Array(songs.filter { $0.count > 0 }.sorted {
                        let a = $0.count, b = $1.count
                        return a == b ? $0.title < $1.title : a > b
                    }.prefix(10))) { song in row(song.title, "\(song.count)回") }
                }
                Section("最近再生した曲") {
                    ForEach(Array(songs.filter { $0.lastPlayed != nil }.sorted {
                        ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
                    }.prefix(20))) { song in
                        row(song.title, (song.lastPlayed ?? .distantPast).formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("アーティスト別 再生回数") {
                    ForEach(Array(artists.filter { $0.count > 0 }.sorted {
                        $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
                    }.prefix(10))) { row($0.name,"\($0.count)回") }
                }
                Section("アーティスト別 再生時間") {
                    ForEach(Array(artists.filter { $0.seconds > 0 }.sorted {
                        $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds
                    }.prefix(10))) { row($0.name,StatisticsQuery.timeText($0.seconds)) }
                }
            }.navigationTitle("再生統計").toolbar { Button("閉じる") { dismiss() } }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).lineLimit(1); Spacer(); Text(value).font(.caption).foregroundStyle(.secondary) }
    }
}
