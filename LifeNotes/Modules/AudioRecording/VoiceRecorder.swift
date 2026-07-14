import Foundation

enum VoiceRecorderError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case unableToStart
    case noActiveRecording
    case recordingLimitReached

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "没有麦克风权限，无法开始录音。"
        case .unableToStart:
            return "暂时无法开始录音，请稍后重试。"
        case .noActiveRecording:
            return "当前没有可继续的录音。"
        case .recordingLimitReached:
            return "单段录音最长为 60 秒。"
        }
    }
}

@MainActor
protocol VoiceRecorder: AnyObject {
    var currentDurationMilliseconds: Int { get }
    var isRecording: Bool { get }
    var onRecordingInterrupted: (@MainActor @Sendable () -> Void)? { get set }

    func requestPermission() async -> Bool
    func startRecording(to fileURL: URL, maximumDuration: TimeInterval) throws
    func pauseRecording()
    func resumeRecording(maximumDuration: TimeInterval) throws
    func stopRecording()
    func cancelRecording()
}
