import AVFoundation
import Foundation

struct NativeOpusProbe {
    let mode: String
    let duration: Double?
    let detail: String
    static var os: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func inspect(_ url: URL) async -> NativeOpusProbe {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            if player.prepareToPlay(), player.duration.isFinite, player.duration > 0 {
                return NativeOpusProbe(mode: "audioPlayer", duration: player.duration,
                    detail: "AVAudioPlayer準備成功。音声出力は再生時に確認。")
            }
        } catch { /* Test AVPlayer independently below. */ }
        return await inspectAVPlayer(url)
    }
    static func inspectAVPlayer(_ url: URL) async -> NativeOpusProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard try await asset.load(.isPlayable) else {
                return NativeOpusProbe(mode: "decoder", duration: nil, detail: "AVPlayer asset.isPlayable=false")
            }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            defer { player.replaceCurrentItem(with: nil) }
            for _ in 0..<60 {
                try Task.checkCancellation()
                if item.status == .failed {
                    return NativeOpusProbe(mode: "decoder", duration: nil, detail: "AVPlayerItem failed: \(item.error?.localizedDescription ?? "")")
                }
                if item.status == .readyToPlay {
                    let seconds = try await asset.load(.duration).seconds
                    return NativeOpusProbe(mode: "avPlayer", duration: seconds.isFinite && seconds > 0 ? seconds : nil,
                        detail: "AVPlayerItem readyToPlay。音声出力は再生時に確認。")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return NativeOpusProbe(mode: "decoder", duration: nil, detail: "AVPlayer準備が3秒以内に完了しませんでした")
        } catch {
            return NativeOpusProbe(mode: "decoder", duration: nil, detail: "AVPlayer読み込み失敗: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class NativeFilePlayer {
    private let player: AVPlayer
    private var status: NSKeyValueObservation?
    private var control: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var terminal = false
    private var requestedPlay = false
    private var seekPosition: Double?
    private var seekGeneration = 0
    private var seeking = false
    private var pausedPosition: Double?
    private let expectedDuration: Double?
    var onStart: (() -> Void)?
    var onFinish: ((Error?) -> Void)?
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seekPosition ?? pausedPosition ?? (seconds.isFinite ? max(0, seconds) : 0)
    }
    init(url: URL, duration: Double? = nil) {
        expectedDuration = duration
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed, error = item.error
            Task { @MainActor [weak self] in
                if failed { self?.finish(error ?? LibraryError.invalidAudio) }
                else { self?.pump() }
            }
        }
        control = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let active = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, active, self.isPlaying, self.requestedPlay, !self.terminal else { return }
                self.watchdog?.cancel()
                self.onStart?()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.requestedPlay, self.seekPosition == nil else { return }
                    self.finish(nil)
                }
            })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in self?.finish(error ?? LibraryError.invalidAudio) }
            })
    }
    deinit {
        watchdog?.cancel()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        player.pause()
    }
    func play() {
        terminal = false; requestedPlay = true
        if seekPosition == nil, let pausedPosition { seekPosition = pausedPosition; seekGeneration += 1 }
        pump()
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.requestedPlay, !self.isPlaying else { return }
            self.finish(LibraryError.invalidAudio)
        }
    }
    func pause() {
        let retained = currentTime
        requestedPlay = false; watchdog?.cancel(); player.pause()
        pausedPosition = retained
    }
    func stop() {
        terminal = true; pause()
        seekGeneration += 1; seeking = false
        player.currentItem?.cancelPendingSeeks()
        seekPosition = 0; pausedPosition = 0
    }
    func seek(to seconds: Double) {
        seekGeneration += 1; seeking = false
        player.currentItem?.cancelPendingSeeks()
        seekPosition = seconds
        if !requestedPlay { pausedPosition = seconds }
        pump()
    }
    private func pump() {
        guard !terminal, player.currentItem?.status == .readyToPlay else { return }
        if let target = seekPosition {
            guard !seeking else { return }
            seeking = true
            let token = seekGeneration
            player.pause()
            player.seek(to: CMTime(seconds: target, preferredTimescale: 48000),
                toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                Task { @MainActor [weak self] in
                    guard let self, self.seekGeneration == token, !self.terminal else { return }
                    self.seeking = false
                    let actual = self.player.currentTime().seconds
                    guard completed, actual.isFinite, abs(actual - target) <= 0.35 else {
                        // Keep the requested position for the streaming fallback.
                        self.finish(LibraryError.invalidAudio)
                        return
                    }
                    self.seekPosition = nil
                    self.pausedPosition = self.requestedPlay ? nil : actual
                    if self.requestedPlay { self.player.play() }
                }
            }
        } else if requestedPlay {
            pausedPosition = nil
            player.play()
        }
    }
    private func finish(_ error: Error?) {
        guard !terminal else { return }
        terminal = true; pause(); onFinish?(error)
    }
}