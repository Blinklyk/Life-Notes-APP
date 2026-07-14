import Foundation
import Speech

@MainActor
final class SystemSpeechTranscriber: SpeechTranscriber {
    private var activeTask: SFSpeechRecognitionTask?
    private var activeWaiter: SpeechRecognitionWaiter?

    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptResult {
        cancel()

        let authorizationStatus = await authorizationStatus()
        switch authorizationStatus {
        case .authorized:
            break
        case .denied:
            throw SpeechTranscriberError.permissionDenied
        case .restricted:
            throw SpeechTranscriberError.restricted
        case .notDetermined:
            throw SpeechTranscriberError.permissionDenied
        @unknown default:
            throw SpeechTranscriberError.restricted
        }
        try Task.checkCancellation()

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        if recognizer.supportsOnDeviceRecognition {
            do {
                let text = try await recognize(
                    fileURL: fileURL,
                    recognizer: recognizer,
                    requiresOnDeviceRecognition: true
                )
                return SpeechTranscriptResult(text: text, source: .onDevice)
            } catch is CancellationError {
                throw CancellationError()
            } catch SpeechTranscriberError.noSpeech {
                throw SpeechTranscriberError.noSpeech
            } catch {
                // 设备内识别不可用时，用同一系统能力联网重试一次。
            }
        }

        guard recognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable
        }
        let text = try await recognize(
            fileURL: fileURL,
            recognizer: recognizer,
            requiresOnDeviceRecognition: false
        )
        return SpeechTranscriptResult(text: text, source: .network)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeWaiter?.cancel()
        activeWaiter = nil
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    private func recognize(
        fileURL: URL,
        recognizer: SFSpeechRecognizer,
        requiresOnDeviceRecognition: Bool
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        let waiter = SpeechRecognitionWaiter()
        activeWaiter = waiter
        defer {
            activeTask = nil
            activeWaiter = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                activeTask = recognizer.recognitionTask(with: request) {
                    @Sendable result, error in
                    let text = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal == true
                    let failure = error.map(SpeechRecognitionFailure.init)
                    Task { @MainActor [weak waiter] in
                        waiter?.receive(
                            text: text,
                            isFinal: isFinal,
                            failure: failure
                        )
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }
}

private struct SpeechRecognitionFailure: Sendable {
    let message: String

    init(_ error: any Error) {
        message = (error as NSError).localizedDescription
    }
}

@MainActor
private final class SpeechRecognitionWaiter {
    private var continuation: CheckedContinuation<String, any Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<String, any Error>) {
        guard !isFinished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func receive(
        text: String?,
        isFinal: Bool,
        failure: SpeechRecognitionFailure?
    ) {
        guard !isFinished else {
            return
        }
        if let failure {
            finish(
                throwing: SpeechTranscriberError.recognitionFailed(
                    failure.message
                )
            )
            return
        }
        guard isFinal else {
            return
        }

        let normalizedText = (text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            finish(throwing: SpeechTranscriberError.noSpeech)
            return
        }
        finish(returning: normalizedText)
    }

    func cancel() {
        finish(throwing: CancellationError())
    }

    private func finish(returning text: String) {
        guard !isFinished else {
            return
        }
        isFinished = true
        continuation?.resume(returning: text)
        continuation = nil
    }

    private func finish(throwing error: any Error) {
        guard !isFinished else {
            return
        }
        isFinished = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
