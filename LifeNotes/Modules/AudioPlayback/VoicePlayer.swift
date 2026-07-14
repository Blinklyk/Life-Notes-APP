import Foundation

enum VoicePlayerError: LocalizedError, Equatable {
    case unableToPlay

    var errorDescription: String? {
        "暂时无法播放这段录音。"
    }
}

@MainActor
protocol VoicePlayer: AnyObject {
    var isPlaying: Bool { get }
    var currentTimeMilliseconds: Int { get }
    var durationMilliseconds: Int { get }
    var onPlaybackInterrupted: (@MainActor @Sendable () -> Void)? { get set }

    func play(fileURL: URL) throws
    func pause()
    func resume() throws
    func stop()
}
