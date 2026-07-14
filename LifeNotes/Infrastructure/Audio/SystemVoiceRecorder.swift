import AVFoundation
import Foundation

@MainActor
final class SystemVoiceRecorder: NSObject, VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var isPaused = false
    var onRecordingInterrupted: (@MainActor @Sendable () -> Void)?

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

    var currentDurationMilliseconds: Int {
        guard let recorder else {
            return 0
        }
        return max(0, Int((recorder.currentTime * 1_000).rounded()))
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording(
        to fileURL: URL,
        maximumDuration: TimeInterval
    ) throws {
        cancelRecording()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
                throw VoiceRecorderError.unableToStart
            }
            self.recorder = recorder
            isPaused = false
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            self.recorder = nil
            isPaused = false
            if let recorderError = error as? VoiceRecorderError {
                throw recorderError
            }
            throw VoiceRecorderError.unableToStart
        }
    }

    func pauseRecording() {
        guard recorder?.isRecording == true else {
            return
        }
        recorder?.pause()
        isPaused = true
    }

    func resumeRecording(maximumDuration: TimeInterval) throws {
        guard let recorder, isPaused else {
            throw VoiceRecorderError.noActiveRecording
        }
        let remainingDuration = maximumDuration - recorder.currentTime
        guard remainingDuration > 0 else {
            throw VoiceRecorderError.recordingLimitReached
        }
        guard recorder.record(forDuration: remainingDuration) else {
            throw VoiceRecorderError.unableToStart
        }
        isPaused = false
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        isPaused = false
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
        notifyRecordingInterrupted()
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
        notifyRecordingInterrupted()
    }

    @objc
    nonisolated private func handleMediaServicesReset(_ notification: Notification) {
        notifyRecordingInterrupted()
    }

    nonisolated private func notifyRecordingInterrupted() {
        Task { @MainActor [weak self] in
            self?.onRecordingInterrupted?()
        }
    }
}
