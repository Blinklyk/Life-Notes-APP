import Foundation

enum SpeechRecognitionSource: String, Codable, Equatable, Sendable {
    case onDevice
    case network
}

struct SpeechTranscriptResult: Equatable, Sendable {
    let text: String
    let source: SpeechRecognitionSource
}

enum SpeechTranscriberError: LocalizedError, Equatable {
    case permissionDenied
    case restricted
    case recognizerUnavailable
    case noSpeech
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有语音识别权限，录音仍可保留和播放。"
        case .restricted:
            return "当前设备不允许使用语音识别，录音仍可保留和播放。"
        case .recognizerUnavailable:
            return "语音识别暂时不可用，请稍后重试。"
        case .noSpeech:
            return "没有识别出可用文字，你仍可保留原始录音。"
        case let .recognitionFailed(message):
            return message.isEmpty ? "语音转写失败，请稍后重试。" : message
        }
    }
}

@MainActor
protocol SpeechTranscriber: AnyObject {
    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptResult

    func cancel()
}
