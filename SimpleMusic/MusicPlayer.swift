import AVFoundation
import Foundation
import Combine
import CallKit
import MediaPlayer
import SwiftUI

@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage = ""
    private var player: AVAudioPlayer?
    private var stream: OpusStreamPlayer?
    private var playbackToken = UUID()
    private var nativeFile: NativeFilePlayer?
    private var nativeTask: Task<Void, Never>?
    private var wantsPlayback = false
    private var hasStartedPlayback = false
    private var interruptedPosition: Double?
    private var recovery = PlaybackRecovery()
    private let defaults: UserDefaults
    private let callObserver = CXCallObserver()
    @Published private(set) var carAudioRoute: CarAudioRoute?
    private var streamTracks = Set<UUID>()
    @Published private(set) var isPreparing = false
    @Published private(set) var backendLabel = ""
    @Published private(set) var nativeDiagnostic = ""
    private var ended = false
    private var libraryDeletionInProgress = false
    private var delayedNext = false
    @Published private(set) var queue: [Track] = []
    @Published private(set) var priorityLoop = false
    private let normalization: NormalizationModel?
    private let artwork: ArtworkModel?
    private var artworkKey = ""
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void,Never>?
    private let preferences: PlaybackPreferences?
    private var countedSession = false
    private var sessionListened: Double = 0
    private var unsavedListened: Double = 0
    private var pendingCount = false
    private var listenedAt: Date?
    private var meter = ListeningMeter()
    private var refreshTimer: Timer?
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var shuffleEnabled = false
    private var restoredQueue = false
    private var lastCheckpoint = Date.distantPast
    private var directory = LibraryStore.defaultDirectory
    private var observers: [NSObjectProtocol] = []
    private var remoteCommands: [MPRemoteCommand] = []

    init(preferences: PlaybackPreferences? = nil, normalization: NormalizationModel? = nil,
         artwork: ArtworkModel? = nil, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.normalization = normalization
        self.artwork = artwork
        self.defaults = defaults
        super.init()
        carAudioRoute = defaults.data(forKey: PlaybackRecovery.carRouteKey)
            .flatMap { try? JSONDecoder().decode(CarAudioRoute.self, from: $0) }
        refreshTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying || self.isPreparing || (self.wantsPlayback && !self.ended) else { return }
                self.refresh()
            }
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
        let center = MPRemoteCommandCenter.shared()
        let bindings: [(MPRemoteCommand, Selector)] = [
            (center.playCommand, #selector(remotePlay(_:))),
            (center.pauseCommand, #selector(remotePause(_:))),
            (center.togglePlayPauseCommand, #selector(remoteToggle(_:))),
            (center.stopCommand, #selector(remoteStop(_:))),
            (center.nextTrackCommand, #selector(remoteNext(_:))),
            (center.previousTrackCommand, #selector(remotePrevious(_:))),
            (center.changePlaybackPositionCommand, #selector(remoteSeek(_:)))
        ]
        for (command, selector) in bindings {
            command.addTarget(self, action: selector)
            remoteCommands.append(command)
        }
        observeInterruptions()
        for event in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor [weak self] in self?.refresh(); self?.checkpoint() } })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated {
                self?.handleRouteChange(reason, previousOutputs: Set(previous?.outputs.map(\.uid) ?? []))
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let stream = self.stream, stream.ownsEngine(note.object) else { return }
                do { try stream.reconfigure(); self.refresh() }
                catch { self.pause(); self.errorMessage = "音声出力を再開できません: \(error.localizedDescription)" }
            }
        })
    }

    deinit {
        refreshTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        remoteCommands.forEach { $0.removeTarget(self) }
    }

    @objc func remotePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noSuchContent }
        guard !recovery.interrupted else { return .commandFailed }
        if defaults.string(forKey: PlaybackRecovery.carTrackKey) != nil {
            resumeForCar()
            return isPlaying || isPreparing ? .success : .commandFailed
        }
        if !isPlaying && !isPreparing { resumeManually() }
        return isPlaying || isPreparing ? .success : .commandFailed
    }
    @objc func remotePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noSuchContent }
        pause(); return .success
    }
    @objc func remoteToggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noSuchContent }
        toggle(); return errorMessage.isEmpty ? .success : .commandFailed
    }
    @objc func remoteStop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noSuchContent }
        stop(); return .success
    }
    @objc func remoteNext(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard canNext else { return .noSuchContent }
        next(); return isPlaying || isPreparing ? .success : .commandFailed
    }
    @objc func remotePrevious(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard canPrevious else { return .noSuchContent }
        previous(); return isPlaying || isPreparing ? .success : .commandFailed
    }
    @objc func remoteSeek(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard player != nil || stream != nil || nativeFile != nil, let event = event as? MPChangePlaybackPositionCommandEvent,
              event.positionTime.isFinite else { return .commandFailed }
        seek(to: event.positionTime); return .success
    }

    private func updateNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = current != nil
        center.pauseCommand.isEnabled = current != nil
        center.togglePlayPauseCommand.isEnabled = current != nil
        center.stopCommand.isEnabled = current != nil
        center.nextTrackCommand.isEnabled = canNext
        center.previousTrackCommand.isEnabled = canPrevious
        center.changePlaybackPositionCommand.isEnabled = player != nil || stream != nil || nativeFile != nil
        guard let current else { return }
        refreshArtwork(for: current)
        var info: [String:Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artistLabel,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queue.firstIndex(of: current) ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateArtwork() {
        guard player != nil || stream != nil || nativeFile != nil else { return }
        updateNowPlaying()
    }
    private func refreshArtwork(for track: Track) {
        let key = "\(track.id)-\(artwork?.revisions[track.sha256, default:0] ?? 0)"
        guard key != artworkKey else { return }
        artworkKey = key; artworkTask?.cancel(); nowPlayingArtwork = nil
        guard let artwork else { return }
        artworkTask = Task { @MainActor [weak self] in
            let image = await artwork.image(for: track)
            guard let self, !Task.isCancelled, self.current?.id == track.id, self.artworkKey == key else { return }
            if let image {
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize:image.size) { _ in image }
            }
            self.updateNowPlaying()
        }
    }

    var canPrevious: Bool {
        guard !libraryDeletionInProgress, let current, let index = queue.firstIndex(of: current) else { return false }
        return index > 0 || (repeatMode != .off && queue.count > 1)
    }
    var canNext: Bool {
        guard !libraryDeletionInProgress else { return false }
        guard let current, let index = queue.firstIndex(of: current) else { return false }
        return index + 1 < queue.count || (repeatMode == .all && !queue.isEmpty) || (repeatMode == .one && queue.count > 1)
    }

    func restoreQueue(from tracks: [Track], directory: URL = LibraryStore.defaultDirectory) {
        self.directory = directory
        guard !restoredQueue else { return }
        restoredQueue = true
        guard let preferences, preferences.ready else { return }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        queue = preferences.state.queueIDs.compactMap { byID[$0] }
        current = preferences.state.currentID.flatMap { byID[$0] }
        repeatMode = preferences.state.repeatMode
        shuffleEnabled = preferences.state.shuffleEnabled
        priorityLoop = repeatMode == .all && shuffleEnabled && !queue.isEmpty
        duration = current?.duration ?? 0
        position = min(preferences.state.currentPosition, duration)
        countedSession = preferences.state.sessionCounted
        sessionListened = preferences.state.sessionListened
        unsavedListened = 0; pendingCount = false; listenedAt = nil
        meter.reset(position: position, time: ProcessInfo.processInfo.systemUptime, playing: false)
        if current != nil {
            interruptedPosition = position
            if position >= duration { interruptedPosition = 0; position = 0; countedSession = false; sessionListened = 0; meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false) }
        }
        persistQueue()
        // Restore the selection only. Do not take over the system's Now Playing before playback.
    }

    func adoptRestoredState(from tracks: [Track], pause: Bool) {
        guard let preferences else { return }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        if !pause && isPlaying && current?.id == preferences.state.currentID {
            queue = preferences.state.queueIDs.compactMap { byID[$0] }
            repeatMode = preferences.state.repeatMode; shuffleEnabled = preferences.state.shuffleEnabled
            priorityLoop = repeatMode == .all && shuffleEnabled
            updateNowPlaying(); return
        }
        cancelAutomaticPlayback()
        playbackToken = UUID(); nativeTask?.cancel(); nativeTask = nil
        nativeFile?.stop(); nativeFile = nil; stream?.stop(); stream = nil; player?.stop(); player = nil
        isPlaying = false; isPreparing = false; wantsPlayback = false
        current = nil; interruptedPosition = nil; ended = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        restoredQueue = false
        restoreQueue(from: tracks, directory: directory)
    }

    func playFromQueue(_ track: Track) {
        guard queue.contains(where: { $0.id == track.id }) else { return }
        start(track)
    }

    func shufflePlay(_ tracks: [Track]) {
        guard !callInProgress else { return }
        let shuffled = WeightedShuffle.order(tracks, counts: preferences?.state.playCounts ?? [:])
        guard let first = shuffled.first else { return }
        play(first, in: shuffled)
        shuffleEnabled = true
        priorityLoop = repeatMode == .all
        persistQueue()
    }

    func setPriorityLoop(_ enabled: Bool) {
        shuffleEnabled = enabled && !queue.isEmpty
        repeatMode = enabled ? .all : .off
        priorityLoop = shuffleEnabled && repeatMode == .all
        persistQueue(); updateNowPlaying()
    }

    func cycleRepeat() { setRepeatMode(repeatMode.next) }
    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode; priorityLoop = shuffleEnabled && mode == .all
        persistQueue(); updateNowPlaying()
    }

    func enqueue(_ track: Track, next: Bool = false) {
        guard track.id != current?.id else { return }
        // Moving an already queued song does not create a duplicate.
        queue.removeAll { $0.id == track.id }
        if next, let current, let index = queue.firstIndex(of: current) {
            queue.insert(track, at: index + 1)
        } else { queue.append(track) }
        persistQueue(); updateNowPlaying()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ queue.indices.contains($0) }), (0...queue.count).contains(destination) else { return }
        queue.move(fromOffsets: offsets, toOffset: destination)
        persistQueue(); updateNowPlaying()
    }

    func removeQueue(at offsets: IndexSet) {
        queue = queue.enumerated().filter { index, track in
            !offsets.contains(index) || track.id == current?.id
        }.map { $0.element }
        persistQueue(); updateNowPlaying()
    }

    func shuffleUpcoming() {
        let split = current.flatMap { queue.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        queue = Array(queue.prefix(split)) + WeightedShuffle.order(Array(queue.dropFirst(split)),
            counts: preferences?.state.playCounts ?? [:])
        shuffleEnabled = !queue.isEmpty
        priorityLoop = shuffleEnabled && repeatMode == .all
        persistQueue(); updateNowPlaying()
    }

    func clearUpcoming() {
        let split = current.flatMap { queue.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        queue = Array(queue.prefix(split))
        priorityLoop = false; repeatMode = .off
        persistQueue(); updateNowPlaying()
    }

    private func persistQueue() { preferences?.saveQueue(queue, current: current, priorityLoop: priorityLoop, repeatMode: repeatMode, shuffle: shuffleEnabled) }

    func forget(_ track: Track) {
        if current?.id == track.id {
            stop()
            player = nil
            stream = nil
            current = nil
            position = 0
            duration = 0
            errorMessage = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        queue.removeAll { $0.id == track.id }
        if queue.isEmpty { priorityLoop = false }
        persistQueue()
        preferences?.forget(track)
        updateNowPlaying()
    }

    func beginLibraryDeletion(_ ids: Set<UUID>) {
        libraryDeletionInProgress = true; delayedNext = false
        if let current, ids.contains(current.id) { stop() }
        updateNowPlaying()
    }
    func endLibraryDeletion() {
        libraryDeletionInProgress = false
        let advance = delayedNext; delayedNext = false
        if advance && ended { finishAdvance() }
        if !ended { updateNormalization() }
        updateNowPlaying()
    }
    func forgetMany(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        if let current, ids.contains(current.id) {
            stop(); player = nil; stream = nil; self.current = nil
            position = 0; duration = 0; errorMessage = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        queue.removeAll { ids.contains($0.id) }
        if queue.isEmpty { priorityLoop = false }
        preferences?.forgetMany(tracks)
        persistQueue(); updateNowPlaying()
    }

    func play(_ track: Track, in tracks: [Track], directory: URL = LibraryStore.defaultDirectory) {
        guard !callInProgress else { return }
        refresh(); checkpoint()
        shuffleEnabled = false; priorityLoop = false
        var seen = Set<UUID>()
        queue = tracks.filter { seen.insert($0.id).inserted }
        if !queue.contains(where: { $0.id == track.id }) { queue.append(track) }
        self.directory = directory
        start(track)
    }

    private func start(_ track: Track) {
        guard !callInProgress else { return }
        cancelAutomaticPlayback()
        refresh(); checkpoint()
        sessionListened = 0; unsavedListened = 0; pendingCount = false; listenedAt = nil
        meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false)
        playbackToken = UUID()
        nativeTask?.cancel(); nativeTask = nil; isPreparing = false
        nativeFile?.stop(); nativeFile = nil
        wantsPlayback = true
        hasStartedPlayback = false
        interruptedPosition = nil
        stream?.stop(); stream = nil
        player?.stop()
        player = nil
        ended = false
        countedSession = false
        current = track
        isPlaying = false
        position = 0
        duration = track.duration
        errorMessage = ""
        do {
            guard FileManager.default.fileExists(atPath: track.audioURL(in: directory).path) else { throw LibraryError.missingFile }
            try activateSession()
            let url = track.audioURL(in: directory)
            if normalization?.enabled == true || track.usesVorbisDecoder {
                do { try beginStream(track, at: 0) }
                catch {
                    guard normalization?.enabled == true, !track.usesVorbisDecoder else { throw error }
                    normalization?.setEnabled(false)
                    stream?.stop(); stream = nil
                    start(track)
                    errorMessage = "この曲には音量補正を適用できないため、補正をオフにして再生しました。"
                    return
                }
            } else if track.usesOpusDecoder {
                // Always try the actual local bytes with the native audio player first.
                if streamTracks.contains(track.id) {
                    try beginStream(track, at: 0)
                } else if let next = try? AVAudioPlayer(contentsOf: url), next.prepareToPlay(), next.play() {
                    next.delegate = self
                    player = next
                    isPlaying = next.isPlaying
                    backendLabel = "標準再生（AVAudioPlayer）"
                    nativeDiagnostic = "AVAudioPlayerの再生開始成功。実音声は試聴で確認してください。"
                } else if track.nativeOpusMode == "decoder", track.nativeProbeOS == NativeOpusProbe.os {
                    nativeDiagnostic = "AVAudioPlayer再生不可。\(track.nativeProbeDetail ?? "")"
                    try beginStream(track, at: 0)
                } else {
                    beginNativeCheck(track)
                }
            } else {
                let next = try AVAudioPlayer(contentsOf: url)
                next.delegate = self
                next.prepareToPlay()
                guard next.play() else { throw LibraryError.invalidAudio }
                player = next
                isPlaying = next.isPlaying
                backendLabel = "標準再生（AVAudioPlayer）"
                nativeDiagnostic = ""
            }
        } catch {
            wantsPlayback = false
            errorMessage = "再生できません: \(error.localizedDescription)"
            deactivateSession()
        }
        hasStartedPlayback = isPlaying
        updateNowPlaying()
        persistQueue()
        meter.reset(position: position, time: ProcessInfo.processInfo.systemUptime, playing: isPlaying)
        checkpoint()
    }

    func toggle() {
        guard !libraryDeletionInProgress else { return }
        if isPlaying || isPreparing { pause() }
        else { resumeManually() }
    }

    private func resumeManually() {
        cancelAutomaticPlayback()
        // A foreground user command can try again if iOS never delivered an end event.
        if !callInProgress { recovery.endInterruption() }
        resumePlayback()
    }

    private func resumePlayback() {
        guard !libraryDeletionInProgress, !isPlaying, !isPreparing, !callInProgress else { return }
        if let target = interruptedPosition, let current {
            do {
                try activateSession()
                wantsPlayback = true
                ended = false
                if current.usesOpusDecoder || current.usesVorbisDecoder || normalization?.enabled == true {
                    try useSeekableOpus(current, at: target, autoPlay: true)
                } else if player == nil && stream == nil && nativeFile == nil {
                    let next = try AVAudioPlayer(contentsOf: current.audioURL(in: directory))
                    next.delegate = self
                    next.currentTime = target
                    guard next.play() else { throw LibraryError.invalidAudio }
                    player = next
                    interruptedPosition = nil
                    backendLabel = "標準再生（AVAudioPlayer）"
                    refresh(); checkpoint()
                } else if nativeFile != nil {
                    playbackToken = UUID()
                    nativeFile?.stop(); nativeFile = nil
                    beginNativeCheck(current, at: target)
                } else if let stream {
                    try stream.seek(to: target); try stream.play()
                    interruptedPosition = nil; refresh(); checkpoint()
                } else if let player {
                    player.currentTime = target
                    guard player.play() else { throw LibraryError.invalidAudio }
                    interruptedPosition = nil; refresh(); checkpoint()
                }
            } catch {
                wantsPlayback = false
                interruptedPosition = target
                errorMessage = "再開できません: \(error.localizedDescription)"
                isPreparing = false
            }
            return
        }
        if let nativeFile {
            guard !nativeFile.isPlaying else { return }
            do {
                try activateSession(); wantsPlayback = true
                if ended || nativeFile.currentTime >= duration { nativeFile.seek(to: 0); countedSession = false; sessionListened = 0; meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false) }
                ended = false
                nativeFile.play(); isPreparing = true
            } catch { errorMessage = "再開できません: \(error.localizedDescription)"; deactivateSession() }
            return
        }
        if let stream {
            guard !stream.isPlaying else { return }
            do {
                try activateSession(); wantsPlayback = true
                if ended || stream.currentTime >= duration { try stream.seek(to: 0); countedSession = false; sessionListened = 0; meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false) }
                ended = false
                try stream.play()
                errorMessage = ""
                refresh(); checkpoint()
            } catch { errorMessage = "再開できません: \(error.localizedDescription)"; deactivateSession() }
            return
        }
        guard let player else {
            if let current { start(current) }
            return
        }
        if !player.isPlaying {
            do {
                try activateSession(); wantsPlayback = true
                if ended || player.currentTime >= duration {
                    player.currentTime = 0
                    countedSession = false; sessionListened = 0
                    meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false)
                }
                ended = false
                guard player.play() else { throw LibraryError.invalidAudio }
                errorMessage = ""
                refresh(); checkpoint()
            } catch {
                errorMessage = "再開できません: \(error.localizedDescription)"
                deactivateSession()
            }
        }
    }

    private var audioOutputs: Set<String> {
        Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid))
    }

    private var callInProgress: Bool { callObserver.calls.contains { !$0.hasEnded } }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        if #available(iOS 27.0, *) {
            observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
                guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                      context.source == .system else { return }
                let reason = context.interruptionContext?.reason
                MainActor.assumeIsolated {
                    self?.handleInterruptionBegan(routeLost: reason == .routeDisconnected, suspended: reason == .appWasSuspended)
                }
            })
            observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
                guard let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
                MainActor.assumeIsolated { self?.handleInterruptionEnded(shouldResume: context.recommendation == .shouldResume) }
            })
        } else {
            observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    if type == .began {
                        self?.handleInterruptionBegan(routeLost: reason == .routeDisconnected, suspended: reason == .appWasSuspended)
                    } else if type == .ended {
                        self?.handleInterruptionEnded(shouldResume: options.contains(.shouldResume))
                    }
                }
            })
        }
    }

    func handleInterruptionBegan(routeLost: Bool = false, suspended: Bool = false) {
        if suspended && !routeLost {
            if wantsPlayback && !ended { holdPlaybackPosition() }
            return
        }
        let activeTrack = wantsPlayback && hasStartedPlayback && !ended ? current?.id : nil
        recovery.beginInterruption(track: activeTrack, outputs: audioOutputs, routeLost: routeLost)
        if wantsPlayback && !ended { holdPlaybackPosition() }
    }

    func handleInterruptionEnded(shouldResume: Bool) {
        guard recovery.interrupted else { return }
        let selected = recovery.interruptedTrack
        let sameOutputs = recovery.interruptionOutputs == audioOutputs
        recovery.endInterruption()
        guard shouldResume else { cancelAutomaticPlayback(); return }
        guard !callInProgress else { return }
        if let selected, selected == current?.id, sameOutputs { resumePlayback() }
        else { resumeForCar() }
    }

    private func holdPlaybackPosition() {
        let retained = max(position, nativeFile?.currentTime ?? stream?.currentTime ?? player?.currentTime ?? position)
        interruptedPosition = min(retained, duration)
        refresh(); checkpoint()
        wantsPlayback = false
        hasStartedPlayback = false
        playbackToken = UUID()
        nativeTask?.cancel(); nativeTask = nil; isPreparing = false
        nativeFile?.pause(); stream?.pause(); player?.pause()
        if let stream { installStreamCompletion(stream) }
        ended = false
        position = interruptedPosition ?? position
        isPlaying = false
        updateNowPlaying()
        checkpoint()
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason, previousOutputs: Set<String>) {
        let outputs = audioOutputs
        if reason == .oldDeviceUnavailable, !previousOutputs.subtracting(outputs).isEmpty || previousOutputs.isEmpty {
            let wasPlaying = wantsPlayback && !ended
            let track = recovery.takeRouteLoss(currentTrack: current?.id, wasPlaying: wasPlaying && hasStartedPlayback)
            if wasPlaying { holdPlaybackPosition() }
            if let track, let carAudioRoute, previousOutputs.contains(carAudioRoute.id),
               !outputs.contains(carAudioRoute.id), track == current?.id,
               preferences?.ready == true, preferences?.errorMessage.isEmpty == true {
                defaults.set(track.uuidString, forKey: PlaybackRecovery.carTrackKey)
            }
            if wasPlaying { deactivateSession() }
        } else if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
            resumeForCar()
        }
    }

    func resumeForCar() {
        let ticket = defaults.string(forKey: PlaybackRecovery.carTrackKey).flatMap(UUID.init(uuidString:))
        guard !libraryDeletionInProgress, !isPlaying, !isPreparing, !ended, position < duration,
              PlaybackRecovery.canResumeCar(ticket: ticket, currentTrack: current?.id, carID: carAudioRoute?.id,
                  outputs: audioOutputs, interrupted: recovery.interrupted, callInProgress: callInProgress) else { return }
        cancelAutomaticPlayback()
        resumePlayback()
    }

    @discardableResult
    func registerCarAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard outputs.count == 1, let output = outputs.first,
              [.bluetoothA2DP, .bluetoothLE, .carAudio].contains(output.portType) else { return false }
        let route = CarAudioRoute(id: output.uid, name: output.portName)
        guard let data = try? JSONEncoder().encode(route) else { return false }
        cancelAutomaticPlayback()
        defaults.set(data, forKey: PlaybackRecovery.carRouteKey)
        carAudioRoute = route
        return true
    }

    func removeCarAudioRoute() {
        cancelAutomaticPlayback()
        defaults.removeObject(forKey: PlaybackRecovery.carRouteKey)
        carAudioRoute = nil
    }

    private func cancelAutomaticPlayback() {
        recovery.cancelAutomaticPlayback()
        defaults.removeObject(forKey: PlaybackRecovery.carTrackKey)
    }

    func pause() {
        cancelAutomaticPlayback()
        refresh(); checkpoint()
        delayedNext = false
        wantsPlayback = false
        hasStartedPlayback = false
        nativeTask?.cancel(); nativeTask = nil; isPreparing = false
        nativeFile?.pause(); stream?.pause(); player?.pause()
        refresh(); checkpoint(); deactivateSession()
    }
    func stop() {
        cancelAutomaticPlayback()
        refresh(); checkpoint()
        sessionListened = 0; meter.reset(position: 0, time: ProcessInfo.processInfo.systemUptime, playing: false)
        delayedNext = false
        wantsPlayback = false
        hasStartedPlayback = false
        interruptedPosition = nil
        playbackToken = UUID()
        nativeTask?.cancel(); nativeTask = nil; isPreparing = false
        nativeFile?.stop(); nativeFile = nil
        // Stop invalidates callbacks, and a later resume must install a fresh completion token.
        stream?.stop()
        if let stream { installStreamCompletion(stream) }
        player?.stop()
        player?.currentTime = 0
        countedSession = false
        ended = false
        refresh()
        position = 0
        isPlaying = false
        updateNowPlaying()
        checkpoint()
        deactivateSession()
    }
    func seek(to seconds: Double) {
        guard !libraryDeletionInProgress else { return }
        guard seconds.isFinite else { return }
        refresh(); checkpoint()
        if ended { sessionListened = 0; countedSession = false }
        let target = min(max(0, seconds), duration)
        meter.reset(position: target, time: ProcessInfo.processInfo.systemUptime, playing: wantsPlayback && interruptedPosition == nil)
        if interruptedPosition != nil {
            interruptedPosition = target; position = target; ended = false; updateNowPlaying(); checkpoint()
            return
        }
        if let current, current.usesOpusDecoder, stream == nil {
            do { try useSeekableOpus(current, at: target, autoPlay: wantsPlayback) }
            catch { errorMessage = "指定位置から再生できません: \(error.localizedDescription)" }
        } else if let nativeFile { nativeFile.seek(to: target) }
        else if let stream {
            do { try stream.seek(to: target) }
            catch { errorMessage = "シークできません: \(error.localizedDescription)"; stream.pause(); deactivateSession() }
        } else if let player { player.currentTime = target }
        else { return }
        ended = false
        refresh()
        checkpoint()
    }
    func next() {
        guard !libraryDeletionInProgress else { return }
        guard let current, let index = queue.firstIndex(of: current) else { return }
        if index + 1 < queue.count { start(queue[index + 1]) }
        else if repeatMode != .off {
            if shuffleEnabled { queue = WeightedShuffle.cycle(queue, counts: preferences?.state.playCounts ?? [:], avoiding: current.id) }
            if let first = queue.first { start(first) }
        }
    }
    func previous() {
        guard !libraryDeletionInProgress else { return }
        guard let current, let index = queue.firstIndex(of: current) else { return }
        if index > 0 { start(queue[index - 1]) }
        else if repeatMode != .off, queue.count > 1, let last = queue.last { start(last) }
    }
    func checkpoint(force: Bool = true) {
        guard let current, preferences?.ready == true else { return }
        if !force, Date().timeIntervalSince(lastCheckpoint) < 5 { return }
        preferences?.saveProgress(for: current, seconds: interruptedPosition ?? position, counted: countedSession,
            listened: sessionListened, additional: unsavedListened, lastPlayed: listenedAt, incrementCount: pendingCount)
        if preferences?.errorMessage.isEmpty == true { unsavedListened = 0; pendingCount = false; listenedAt = nil }
        lastCheckpoint = Date()
    }

    func refresh() {
        guard player != nil || stream != nil || nativeFile != nil else { return }
        position = interruptedPosition ?? (ended ? duration : min(nativeFile?.currentTime ?? stream?.currentTime ?? player?.currentTime ?? 0, duration))
        isPlaying = nativeFile?.isPlaying ?? stream?.isPlaying ?? player?.isPlaying ?? false
        if isPlaying && wantsPlayback { hasStartedPlayback = true }
        measure(position: position, playing: isPlaying)
        updateNowPlaying()
        if isPlaying { checkpoint(force: false) }
    }
    private func measure(position: Double, playing: Bool) {
        guard let current else { return }
        let delta = meter.sample(position: position, time: ProcessInfo.processInfo.systemUptime, playing: playing)
        if delta > 0 {
            sessionListened += delta; unsavedListened += delta
            if listenedAt == nil { listenedAt = Date() }
            recordCountIfEligible(completed: false)
        }
    }
    private func recordCountIfEligible(completed: Bool) {
        guard let current, !countedSession,
              ListeningMeter.shouldCount(listened: sessionListened, duration: current.duration, completed: completed) else { return }
        countedSession = true; pendingCount = true; checkpoint()
    }
    private func finishAdvance() {
        if repeatMode == .one, let current { start(current) }
        else if canNext { next() }
        else { ended = true; wantsPlayback = false; position = duration; deactivateSession() }
    }
    func synchronizeLibrary(_ tracks: [Track]) {
        guard restoredQueue else { return }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        queue = queue.compactMap { byID[$0.id] }
        if let selected = current, let updated = byID[selected.id] {
            // A legacy WAV can be replaced while its old file is still open.
            // Keep the active backend until the next explicit start.
            current = updated
        }
        persistQueue(); updateNowPlaying()
    }
    private func useSeekableOpus(_ track: Track, at target: Double, autoPlay: Bool) throws {
        // AVPlayer can report a successful Ogg seek while audible audio restarts.
        // Prepare the decoder before releasing a supported native-only file.
        let next = try OpusStreamPlayer(url: track.audioURL(in: directory), gain: normalization?.gain(for: track) ?? 1)
        try next.seek(to: target)
        if autoPlay { try activateSession() }
        playbackToken = UUID()
        nativeTask?.cancel(); nativeTask = nil
        nativeFile?.pause(); nativeFile = nil
        player?.pause(); player = nil
        stream?.stop()
        stream = next
        installStreamCompletion(next)
        streamTracks.insert(track.id)
        if autoPlay { try next.play() }
        wantsPlayback = autoPlay
        interruptedPosition = nil
        ended = false
        isPreparing = false
        errorMessage = ""
        position = next.currentTime
        duration = next.duration
        backendLabel = track.usesVorbisDecoder ? "Ogg Vorbisストリーミング" : (track.usesOpusDecoder ? "互換再生（Opusストリーミング）" : "音量補正ストリーミング")
        nativeDiagnostic = "指定位置へPCM単位で移動します。元の圧縮ファイルを保持します。"
        isPlaying = next.isPlaying
        if isPlaying { hasStartedPlayback = true }
        meter.reset(position: position, time: ProcessInfo.processInfo.systemUptime, playing: isPlaying)
        updateNowPlaying()
        checkpoint()
    }

    func updateNormalization() {
        guard !libraryDeletionInProgress else { return }
        guard let current, let normalization else { return }
        refresh()
        do {
            if let stream {
                try stream.setGain(normalization.gain(for: current))
                refresh(); checkpoint()
            } else if normalization.enabled, player != nil || nativeFile != nil || isPreparing {
                let target = interruptedPosition ?? position
                let wasInterrupted = interruptedPosition != nil
                try useSeekableOpus(current, at: target, autoPlay: wantsPlayback && !wasInterrupted)
                if wasInterrupted { interruptedPosition = target; position = target; checkpoint() }
            }
        } catch {
            normalization.setEnabled(false)
            errorMessage = "この曲には音量補正を適用できません: \(error.localizedDescription)"
        }
    }

    private func beginStream(_ track: Track, at position: Double, autoPlay: Bool = true) throws {
        let next = try OpusStreamPlayer(url: track.audioURL(in: directory), gain: normalization?.gain(for: track) ?? 1)
        installStreamCompletion(next)
        stream = next
        if position > 0 { try next.seek(to: position) }
        if autoPlay { try next.play() }
        interruptedPosition = nil
        self.position = position
        duration = next.duration
        isPreparing = false
        backendLabel = track.usesVorbisDecoder ? "Ogg Vorbisストリーミング" : (track.usesOpusDecoder ? "互換再生（Opusストリーミング）" : "音量補正ストリーミング")
        isPlaying = next.isPlaying
        if isPlaying { hasStartedPlayback = true }
        meter.reset(position: position, time: ProcessInfo.processInfo.systemUptime, playing: isPlaying)
        updateNowPlaying()
    }
    private func beginNativeCheck(_ track: Track, at position: Double = 0) {
        let token = playbackToken
        isPreparing = true
        backendLabel = "標準再生を確認中"
        nativeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let probe = await NativeOpusProbe.inspectAVPlayer(track.audioURL(in: self.directory))
            guard !Task.isCancelled, self.playbackToken == token, self.wantsPlayback else { return }
            self.nativeTask = nil
            self.nativeDiagnostic = "AVAudioPlayer再生不可。\(probe.detail)"
            do {
                if probe.mode == "avPlayer" {
                    let next = NativeFilePlayer(url: track.audioURL(in: self.directory), duration: track.duration)
                    self.nativeFile = next
                    self.backendLabel = "標準再生（AVPlayer）"
                    next.onStart = { [weak self, weak next] in
                        guard let self, self.playbackToken == token, self.wantsPlayback, next?.isPlaying == true else { return }
                        self.isPreparing = false
                        self.interruptedPosition = nil
                        self.nativeDiagnostic = "AVPlayerの再生状態がplayingになりました。実音声は試聴で確認してください。"
                        self.meter.reset(position: next?.currentTime ?? position, time: ProcessInfo.processInfo.systemUptime, playing: true)
                        self.refresh()
                        self.checkpoint()
                    }
                    next.onFinish = { [weak self, weak next] error in
                        guard let self, self.playbackToken == token, self.wantsPlayback else { return }
                        if let error {
                            let position = next?.currentTime ?? 0
                            self.nativeFile?.stop(); self.nativeFile = nil
                            self.nativeDiagnostic = "AVPlayer再生失敗: \(error.localizedDescription)"
                            do { try self.beginStream(track, at: position, autoPlay: self.wantsPlayback); self.refresh() }
                            catch { self.isPreparing = false; self.finished(error: error) }
                        } else {
                            self.isPreparing = false; self.finished(error: error)
                        }
                    }
                    try self.activateSession()
                    next.seek(to: position)
                    next.play()
                } else { try self.beginStream(track, at: position) }
            } catch {
                self.isPreparing = false
                self.finished(error: error)
            }
        }
    }
    private func installStreamCompletion(_ stream: OpusStreamPlayer) {
        let token = playbackToken
        stream.onFinish = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.playbackToken == token, self.wantsPlayback else { return }
                self.finished(error: error)
            }
        }
    }
    private func finished(error: Error?) {
        measure(position: error == nil ? duration : position, playing: false)
        recordCountIfEligible(completed: error == nil)
        checkpoint()
        isPlaying = false
        if error == nil && libraryDeletionInProgress {
            delayedNext = true; ended = true; position = duration
            deactivateSession(); updateNowPlaying(); checkpoint(); return
        }
        if let error {
            wantsPlayback = false
            errorMessage = "音声の再生中にエラーが発生しました: \(error.localizedDescription)"
            deactivateSession()
        } else { finishAdvance() }
        updateNowPlaying()
        checkpoint()
    }
    private func activateSession() throws {
        guard !callInProgress else { throw LibraryError.invalidAudio }
        try configureAudioMix()
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func updateAudioMix() {
        guard wantsPlayback else { return }
        do { try configureAudioMix() }
        catch { errorMessage = "音声同時再生の設定を反映できません: \(error.localizedDescription)" }
    }

    private func configureAudioMix() throws {
        let session = AVAudioSession.sharedInstance()
        let enabled = defaults.object(forKey: PlaybackRecovery.mixKey) as? Bool ?? true
        let options: AVAudioSession.CategoryOptions = enabled ? [.mixWithOthers] : []
        if session.category != .playback || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(.playback, mode: .default, options: options)
        }
    }
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, self.wantsPlayback else { return }
            self.isPlaying = false
            if flag && self.libraryDeletionInProgress { self.finished(error: nil); return }
            if !flag, let track = self.current, track.usesOpusDecoder, self.wantsPlayback {
                let position = player.currentTime
                self.player = nil
                self.beginNativeCheck(track, at: position)
                return
            }
            self.finished(error: flag ? nil : LibraryError.invalidAudio)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, self.wantsPlayback else { return }
            self.isPlaying = false
            if let track = self.current, track.usesOpusDecoder, self.wantsPlayback {
                let position = player.currentTime
                self.player = nil
                self.beginNativeCheck(track, at: position)
                return
            }
            self.errorMessage = "音声の読み取り中にエラーが発生しました"
            self.deactivateSession()
            self.updateNowPlaying()
        }
    }
}

func clockText(_ seconds: Double) -> String {
    let safe = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", safe / 60, safe % 60)
}
