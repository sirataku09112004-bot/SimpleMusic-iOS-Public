import AVFoundation
import Foundation

// Every decoder and node operation is serialized; at most four 12000-frame PCM buffers.
final class OpusStreamPlayer: @unchecked Sendable {
    static let chunkFrames = 12000
    static let maxBuffers = 4
    private let worker = DispatchQueue(label: "SimpleMusic.opus.decode", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder: any PCMDecoder
    private var gain: Double
    private let format: AVAudioFormat
    private var generation = 0
    private var pending = 0
    private var eof = false
    private var playing = false
    private var baseFrame: Int64 = 0
    private var completedFrames: Int64 = 0
    private var lastPosition: Double = 0
    private var decodeFailure: Error?
    private var completion: ((Error?) -> Void)?
    var onFinish: ((Error?) -> Void)? {
        get { worker.sync { completion } }
        set { worker.sync { completion = newValue } }
    }
    let duration: Double
    let channels: Int
    var pcmBudgetBytes: Int { Self.chunkFrames * channels * 4 * Self.maxBuffers }
    init(url: URL, gain: Double = 1) throws {
        decoder = try AudioDecoder.open(url)
        self.gain = gain.isFinite && gain >= 0 ? gain : 1
        duration = decoder.duration
        channels = decoder.channels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: decoder.sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw LibraryError.invalidAudio
        }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    deinit { node.stop(); engine.stop() }
    var isPlaying: Bool { worker.sync { playing } }
    var currentTime: Double { worker.sync { time() } }
    func ownsEngine(_ object: Any?) -> Bool { (object as? AVAudioEngine) === engine }

    private func time() -> Double {
        if let render = node.lastRenderTime, let sample = node.playerTime(forNodeTime: render),
           sample.sampleTime >= 0 {
            lastPosition = min(duration, Double(baseFrame + sample.sampleTime) / decoder.sampleRate)
        } else if eof && pending == 0 { lastPosition = duration }
        return lastPosition
    }

    func play() throws {
        try worker.sync {
            if eof && pending == 0 { try reset(to: 0) }
            if pending == 0 { try refill() }
            try engine.start()
            node.play()
            playing = true
        }
    }
    func pause() {
        worker.sync {
            _ = time()
            playing = false
            node.pause()
            engine.pause()
        }
    }
    func stop() {
        worker.sync {
            generation += 1
            playing = false
            node.stop(); engine.stop()
            pending = 0; eof = false; baseFrame = 0; completedFrames = 0; lastPosition = 0
            decodeFailure = nil
            try? decoder.seek(frame: 0)
        }
    }
    func seek(to seconds: Double) throws {
        try worker.sync {
            let resume = playing
            try reset(to: seconds)
            try refill()
            if resume && pending > 0 {
                try engine.start(); node.play(); playing = true
            } else if resume { finish() }
        }
    }
    func setGain(_ value: Double) throws {
        try worker.sync {
            let value = value.isFinite && value >= 0 ? value : 1
            guard value != gain else { return }
            let seconds = time(), resume = playing
            gain = value
            try reset(to: seconds); try refill()
            if resume && pending > 0 { try engine.start(); node.play(); playing = true }
        }
    }
    func reconfigure() throws {
        try worker.sync {
            let seconds = time(), resume = playing
            generation += 1; node.stop(); engine.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try reset(to: seconds); try refill()
            if resume && pending > 0 { try engine.start(); node.play(); playing = true }
        }
    }
    private func reset(to seconds: Double) throws {
        generation += 1; playing = false; node.stop(); engine.pause()
        pending = 0; eof = false; decodeFailure = nil; completedFrames = 0
        baseFrame = min(decoder.frames, max(0, Int64(seconds * decoder.sampleRate)))
        lastPosition = Double(baseFrame) / decoder.sampleRate
        try decoder.seek(frame: baseFrame)
    }
    private func refill() throws {
        while pending < Self.maxBuffers && !eof {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)),
                  let output = buffer.floatChannelData else { throw LibraryError.invalidAudio }
            // Small bounded interleaved scratch; the node receives planar float PCM.
            var samples = [Float](repeating: 0, count: Self.chunkFrames * channels)
            let frames = try samples.withUnsafeMutableBufferPointer {
                try decoder.read(into: $0.baseAddress!, capacity: $0.count)
            }
            if frames == 0 { eof = true; break }
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<channels {
                for frame in 0..<frames { output[channel][frame] = PCMVolume.apply(samples[frame * channels + channel], gain: gain) }
            }
            pending += 1
            let token = generation
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.worker.async { [weak self] in self?.consumed(frames: frames, token: token) }
            }
        }
    }
    private func consumed(frames: Int, token: Int) {
        guard token == generation else { return }
        pending -= 1; completedFrames += Int64(frames)
        lastPosition = min(duration, Double(baseFrame + completedFrames) / decoder.sampleRate)
        guard playing else { return }
        do { try refill() }
        catch { decodeFailure = error; eof = true }
        if eof && pending == 0 { finish() }
    }
    private func finish() {
        playing = false
        node.pause(); engine.pause()
        if decodeFailure == nil { lastPosition = duration }
        let failure = decodeFailure
        let callback = completion, token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.worker.sync(execute: { self.generation == token && self.eof && self.pending == 0 }) else { return }
            callback?(failure)
        }
    }
}

