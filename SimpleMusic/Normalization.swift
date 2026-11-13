import Foundation
import Combine

struct LoudnessProfile: Codable, Equatable, Sendable {
    static let version = 1
    let version: Int
    let rms: Double
    let peak: Double
    let gain: Double
    var valid: Bool {
        version == Self.version && rms.isFinite && rms >= 0 && peak.isFinite && peak >= 0
            && gain.isFinite && gain >= 0 && gain <= pow(10, 12.0 / 20)
    }
    static func make(rms: Double, peak: Double) -> Self {
        // Active-block RMS, not LUFS/ReplayGain. Peak ceiling -1 dBFS, boost capped at +12 dB.
        let gain = rms > 0.000001 && peak > 0
            ? min(0.1 / rms, pow(10, 12.0 / 20), pow(10, -1.0 / 20) / peak) : 1
        return Self(version: version, rms: rms, peak: peak, gain: gain)
    }
}

enum LoudnessAnalyzer {
    static func analyze(_ url: URL) throws -> LoudnessProfile {
        let decoder = try AudioDecoder.open(url)
        var samples = [Float](repeating: 0, count: 12000 * decoder.channels)
        var activeEnergy = 0.0, activeCount: Int64 = 0, peak = 0.0
        var blockEnergy = 0.0, blockCount = 0
        let blockSamples = max(1, Int(decoder.sampleRate * 0.4)) * decoder.channels
        func finishBlock() {
            // Exclude blocks below -60 dBFS so long silence does not request excessive gain.
            if blockCount > 0 && blockEnergy / Double(blockCount) >= 0.000001 {
                activeEnergy += blockEnergy; activeCount += Int64(blockCount)
            }
            blockEnergy = 0; blockCount = 0
        }
        while true {
            try Task.checkCancellation()
            let frames = try samples.withUnsafeMutableBufferPointer {
                try decoder.read(into: $0.baseAddress!, capacity: $0.count)
            }
            if frames == 0 { break }
            for i in 0..<(frames * decoder.channels) {
                let value = Double(samples[i])
                guard value.isFinite else { throw LibraryError.invalidAudio }
                peak = max(peak, abs(value)); blockEnergy += value * value; blockCount += 1
                if blockCount == blockSamples { finishBlock() }
            }
        }
        finishBlock()
        let rms = activeCount > 0 ? sqrt(activeEnergy / Double(activeCount)) : 0
        return .make(rms: rms, peak: peak)
    }
}

actor LoudnessCache {
    let directory: URL
    private var profiles: [String: LoudnessProfile]
    init(directory: URL, profiles: [String: LoudnessProfile]) {
        self.directory = directory; self.profiles = profiles
    }
    static func key(_ track: Track) -> String { track.sha256 + ":" + URL(fileURLWithPath: track.fileName).pathExtension.lowercased() }
    func profile(for track: Track) throws -> LoudnessProfile {
        try Task.checkCancellation()
        let key = Self.key(track)
        if let cached = profiles[key], cached.valid { return cached }
        let result = try LoudnessAnalyzer.analyze(track.audioURL(in: directory))
        try Task.checkCancellation()
        var candidate = profiles; candidate[key] = result
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("loudness-v1.json"), options: .atomic)
        profiles = candidate
        return result
    }
}

@MainActor
final class NormalizationModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var profiles: [String: LoudnessProfile]
    @Published private(set) var analyzing = false
    @Published private(set) var message = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    private let cache: LoudnessCache
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    init(directory: URL = LibraryStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.defaults = defaults; enabled = defaults.bool(forKey: "normalizationEnabled")
        let url = directory.appendingPathComponent("loudness-v1.json")
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: LoudnessProfile].self, from: $0) } ?? [:]
        let validated = saved.filter { $0.value.valid }
        profiles = validated
        cache = LoudnessCache(directory: directory, profiles: validated)
    }
    func setEnabled(_ value: Bool) { enabled = value; defaults.set(value, forKey: "normalizationEnabled") }
    func gain(for track: Track) -> Double { enabled ? (profiles[LoudnessCache.key(track)]?.gain ?? 1) : 1 }
    func hasProfile(_ track: Track) -> Bool { profiles[LoudnessCache.key(track)] != nil }
    func cancelAnalysis() { task?.cancel() }
    func analyze(_ tracks: [Track]) {
        guard !analyzing else { return }
        analyzing = true; completed = 0; total = tracks.count; message = ""
        task = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            defer { self.analyzing = false; self.task = nil }
            for track in tracks {
                do {
                    try Task.checkCancellation()
                    let result = try await self.cache.profile(for: track)
                    self.profiles[LoudnessCache.key(track)] = result
                    self.completed += 1
                } catch is CancellationError {
                    self.message = "解析を中止しました。完了した曲の結果は保存済みです。"; return
                } catch { failures += 1; self.completed += 1 }
                await Task.yield()
            }
            self.message = failures == 0 ? "解析完了（\(self.completed)曲）" : "解析完了。\(failures)曲は解析できず、元の音量で再生します。"
        }
    }
}

// Per-buffer multiplication permits gain > 1 without relying on native volume ranges.
enum PCMVolume {
    static func apply(_ sample: Float, gain: Double) -> Float {
        let value = Double(sample) * gain
        guard value.isFinite else { return 0 }
        return Float(min(1, max(-1, value)))
    }
}
