import Foundation

enum ControlShufflePolicy {
    static func targets(library: [Track], queue: [Track]) -> [Track] {
        let byID = Dictionary(library.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        var seen = Set<UUID>()
        let retained = queue.compactMap { byID[$0.id] }.filter { seen.insert($0.id).inserted }
        return retained.isEmpty ? library : retained
    }
}
