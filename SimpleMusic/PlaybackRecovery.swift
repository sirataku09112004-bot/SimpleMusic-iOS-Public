import Foundation

struct CarAudioRoute: Codable, Equatable {
    let id: String
    let name: String
}

struct PlaybackRecovery {
    static let mixKey = "mixAudioWithOtherApps"
    static let carRouteKey = "carAudioRoute"
    static let carTrackKey = "carResumeTrack"

    private(set) var interrupted = false
    private(set) var interruptedTrack: UUID?
    private(set) var interruptionOutputs = Set<String>()

    // A route-loss interruption can arrive before the route-change notification.
    private(set) var routeLossTrack: UUID?

    mutating func beginInterruption(track: UUID?, outputs: Set<String>, routeLost: Bool) {
        if routeLost {
            routeLossTrack = track ?? interruptedTrack ?? routeLossTrack
            interruptedTrack = nil
        } else if !interrupted {
            interrupted = true
            interruptedTrack = track
            interruptionOutputs = outputs
        }
    }

    mutating func endInterruption() {
        interrupted = false
        interruptedTrack = nil
        interruptionOutputs = []
    }

    mutating func takeRouteLoss(currentTrack: UUID?, wasPlaying: Bool) -> UUID? {
        defer { routeLossTrack = nil; interruptedTrack = nil }
        return wasPlaying ? currentTrack : (routeLossTrack ?? interruptedTrack)
    }

    mutating func cancelAutomaticPlayback() {
        interruptedTrack = nil
        routeLossTrack = nil
    }

    static func canResumeCar(ticket: UUID?, currentTrack: UUID?, carID: String?, outputs: Set<String>,
                             interrupted: Bool, callInProgress: Bool) -> Bool {
        guard let ticket, let carID else { return false }
        return ticket == currentTrack && outputs == [carID] && !interrupted && !callInProgress
    }
}
