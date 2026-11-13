import Foundation

enum LibrarySort: String, CaseIterable, Identifiable {
    case addedOldest, addedNewest, title, artist, leastPlayed, mostPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addedOldest: return "追加順（古い順）"
        case .addedNewest: return "追加順（新しい順）"
        case .title: return "曲名"
        case .artist: return "アーティスト"
        case .leastPlayed: return "再生回数（少ない順）"
        case .mostPlayed: return "再生回数（多い順）"
        }
    }
}
enum LibraryQuery {
    static func apply(_ tracks: [Track], search: String, favoritesOnly: Bool,
                      favorites: Set<UUID>, counts: [UUID: Int], sort: LibrarySort) -> [Track] {
        let words = normalize(search).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let filtered = tracks.filter { track in
            guard !favoritesOnly || favorites.contains(track.id) else { return false }
            let text = normalize(track.title + " " + track.artistLabel)
            return words.allSatisfy { text.contains($0) }
        }
        return filtered.sorted { a, b in
            switch sort {
            case .addedOldest:
                if a.importedAt != b.importedAt { return a.importedAt < b.importedAt }
            case .addedNewest:
                if a.importedAt != b.importedAt { return a.importedAt > b.importedAt }
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .artist:
                let order = a.artistLabel.localizedStandardCompare(b.artistLabel)
                if order != .orderedSame { return order == .orderedAscending }
                let titles = a.title.localizedStandardCompare(b.title)
                if titles != .orderedSame { return titles == .orderedAscending }
            case .leastPlayed, .mostPlayed:
                let left = counts[a.id] ?? 0, right = counts[b.id] ?? 0
                if left != right { return sort == .leastPlayed ? left < right : left > right }
            }
            if a.importedAt != b.importedAt { return a.importedAt < b.importedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}