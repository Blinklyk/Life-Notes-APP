import AVFoundation
import Foundation

@MainActor
final class SystemVoicePlayer: NSObject, VoicePlayer {
    private var player: AVAudioPlayer?
    var onPlaybackInterrupted: (@MainActor @Sendable () -> Void)?

    override init() {
        super.init()
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    var currentTimeMilliseconds: Int {
        guard let player else {
            return 0
        }
        return max(0, Int((player.currentTime * 1_000).rounded()))
    }

    var durationMilliseconds: Int {
        guard let player else {
            return 0
        }
        return max(0, Int((player.duration * 1_000).rounded()))
    }

    func play(fileURL: URL) throws {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: fileURL)
            guard player.prepareToPlay(), player.play() else {
                throw VoicePlayerError.unableToPlay
            }
            self.player = player
        } catch {
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            if let playerError = error as? VoicePlayerError {
                throw playerError
            }
            throw VoicePlayerError.unableToPlay
        }
    }

    func pause() {
        player?.pause()
    }

    func resume() throws {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard let player, player.play() else {
                throw VoicePlayerError.unableToPlay
            }
        } catch {
            throw VoicePlayerError.unableToPlay
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    @objc
    nonisolated private func handleAudioSessionInterruption(
        _ notification: Notification
    ) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                as? UInt,
            AVAudioSession.InterruptionType(rawValue: rawType) == .began
        else {
            return
        }
        notifyPlaybackInterrupted()
    }

    @objc
    nonisolated private func handleAudioRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason)
                == .oldDeviceUnavailable
        else {
            return
        }
        notifyPlaybackInterrupted()
    }

    @objc
    nonisolated private func handleMediaServicesReset(_ notification: Notification) {
        notifyPlaybackInterrupted()
    }

    nonisolated private func notifyPlaybackInterrupted() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.stop()
            self.onPlaybackInterrupted?()
        }
    }
}
