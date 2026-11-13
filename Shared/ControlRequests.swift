import Foundation
import Combine

@MainActor
final class ControlRequests: ObservableObject {
    static let shared = ControlRequests()
    @Published private(set) var generation = 0
    @Published private(set) var lastAppIntentDate: Date?
    private let defaults: UserDefaults
    private let pendingKey = "control.shuffle.pendingDate"
    private let acceptedKey = "control.shuffle.acceptedDate"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastAppIntentDate = defaults.object(forKey: "control.shuffle.lastAppIntentDate") as? Date
    }

    func recordAppIntent(now: Date = Date()) {
        lastAppIntentDate = now
        defaults.set(now, forKey: "control.shuffle.lastAppIntentDate")
    }

    @discardableResult
    func submit(now: Date = Date()) -> Bool {
        if let pending = defaults.object(forKey: pendingKey) as? Date,
           (0...60).contains(now.timeIntervalSince(pending)) { return false }
        if let last = defaults.object(forKey: acceptedKey) as? Date,
           (0..<2).contains(now.timeIntervalSince(last)) { return false }
        defaults.set(now, forKey: pendingKey); defaults.set(now, forKey: acceptedKey)
        generation += 1
        return true
    }
    func consume(now: Date = Date()) -> Bool {
        guard let date = defaults.object(forKey: pendingKey) as? Date else { return false }
        defaults.removeObject(forKey: pendingKey)
        return (0...60).contains(now.timeIntervalSince(date))
    }
}
