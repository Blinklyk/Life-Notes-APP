import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let maxPhotosPerEntry = 20
    static let maximumVoiceDuration: TimeInterval = 60

    enum Route: Equatable {
        case capture
        case today
    }

    struct Alert: Identifiable {
        let id = UUID()
        let message: String
    }

    struct DraftPhoto: Identifiable, Equatable {
        enum State: Equatable {
            case importing
            case ready(ImportedPhoto)
            case failed
        }

        let id: UUID
        var state: State
        var annotationText: String
    }

    struct DraftVoice: Identifiable, Equatable {
        enum CapturePhase: Equatable {
            case preparing
            case recording
            case paused
            case finalizing
            case ready(ImportedAudio)
            case failed
        }

        let id: UUID
        var targetPhotoID: UUID?
        var capturePhase: CapturePhase
        var keepOriginalAudio: Bool
        var transcriptText: String
        var transcriptionStatus: VoiceTranscriptionStatus
        var transcriptionSource: VoiceTranscriptionSource?
        var sourceLocaleIdentifier: String
        var isTranscriptUserEdited: Bool
    }

    @Published var draftText = "" {
        didSet { scheduleDraftPersistence() }
    }
    @Published private(set) var draftPhotos: [DraftPhoto] = []
    @Published private(set) var draftVoices: [DraftVoice] = []
    @Published private(set) var voiceElapsedMilliseconds = 0
    @Published private(set) var transcribingDraftVoiceID: UUID?
    @Published private(set) var transcribingSavedVoiceIDs: Set<UUID> = []
    @Published private(set) var playbackVoiceID: UUID?
    @Published private(set) var isVoicePlaying = false
    @Published private(set) var voicePlaybackProgress = 0.0
    @Published private(set) var route: Route = .capture
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var todayDate: Date
    @Published private(set) var todayTimeZone: TimeZone
    @Published private(set) var isLoadingToday = false
    @Published private(set) var isSaving = false
    @Published private(set) var isRestoringDraft = true
    @Published private(set) var isCaptureDraftAvailable = true
    @Published private(set) var notice: String?
    @Published var alert: Alert?

    let photoLibrary: any PhotoLibrary
    let audioLibrary: any AudioLibrary

    private let workspace: any DayWorkspace
    private let captureDraftStore: any CaptureDraftStore
    private let voiceRecorder: any VoiceRecorder
    private let speechTranscriber: any SpeechTranscriber
    private let voicePlayer: any VoicePlayer
    private let userID: UUID
    private let now: @Sendable () -> Date
    private let currentTimeZone: @Sendable () -> TimeZone
    private var noticeTask: Task<Void, Never>?
    private var draftPersistenceTask: Task<Void, Never>?
    private var voiceTimerTask: Task<Void, Never>?
    private var voiceTranscriptionTask: Task<Void, Never>?
    private var savedVoiceTranscriptionTask: Task<Void, Never>?
    private var playbackProgressTask: Task<Void, Never>?
    private var draftPersistenceGeneration = 0
    private var suppressDraftPersistence = false
    private var reportedDraftPersistenceError = false
    private var captureDraftID = UUID()
    private var canPersistCaptureDraft = true
    private var voiceGeneration = 0
    private var draftVoiceTranscriptionGeneration = 0
    private var savedVoiceTranscriptionGeneration = 0
    private var playbackGeneration = 0

    init(
        workspace: any DayWorkspace,
        photoLibrary: any PhotoLibrary,
        audioLibrary: any AudioLibrary,
        captureDraftStore: any CaptureDraftStore,
        voiceRecorder: any VoiceRecorder,
        speechTranscriber: any SpeechTranscriber,
        voicePlayer: any VoicePlayer,
        userID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.workspace = workspace
        self.photoLibrary = photoLibrary
        self.audioLibrary = audioLibrary
        self.captureDraftStore = captureDraftStore
        self.voiceRecorder = voiceRecorder
        self.speechTranscriber = speechTranscriber
        self.voicePlayer = voicePlayer
        self.userID = userID
        self.now = now
        self.currentTimeZone = currentTimeZone

        let initialDate = now()
        todayDate = initialDate
        todayTimeZone = currentTimeZone()
        self.voiceRecorder.onRecordingInterrupted = { [weak self] in
            self?.handleVoiceRecordingInterruption()
        }
        self.voicePlayer.onPlaybackInterrupted = { [weak self] in
            self?.stopVoicePlayback()
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            let canReconcileMediaStorage = await self.restoreCaptureDraft()
            await self.refreshToday(showError: false)
            if canReconcileMediaStorage {
                await self.reconcilePhotoStorage()
                await self.reconcileAudioStorage()
            }
        }
    }

    var draftVoice: DraftVoice? {
        draftVoice(forPhotoID: nil)
    }

    var isTranscribingDraftVoice: Bool {
        transcribingDraftVoiceID != nil
    }

    var canSaveDraft: Bool {
        guard isCaptureDraftAvailable, !isSaving, !isRestoringDraft else {
            return false
        }

        guard !isTranscribingDraftVoice else {
            return false
        }

        var readyPhotoCount = 0
        for photo in draftPhotos {
            switch photo.state {
            case .importing, .failed:
                return false
            case .ready:
                readyPhotoCount += 1
            }
        }

        var hasVoice = false
        for draftVoice in draftVoices {
            guard case .ready = draftVoice.capturePhase else {
                return false
            }
            let hasTranscript = !draftVoice.transcriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard draftVoice.keepOriginalAudio || hasTranscript else {
                return false
            }
            hasVoice = true
        }

        let hasText = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || readyPhotoCount > 0 || hasVoice
    }

    var canAddVoice: Bool {
        canAddVoice(targetPhotoID: nil)
    }

    func draftVoice(forPhotoID photoID: UUID?) -> DraftVoice? {
        draftVoices.first { $0.targetPhotoID == photoID }
    }

    func canAddVoice(targetPhotoID: UUID?) -> Bool {
        let hasValidTarget = targetPhotoID.map { photoID in
            draftPhotos.contains { $0.id == photoID }
        } ?? true
        return isCaptureDraftAvailable
            && !isSaving
            && !isRestoringDraft
            && !isImportingPhotos
            && !isVoiceCaptureBusy
            && transcribingSavedVoiceIDs.isEmpty
            && hasValidTarget
            && draftVoice(forPhotoID: targetPhotoID) == nil
    }

    func isTranscribingDraftVoice(id: UUID) -> Bool {
        transcribingDraftVoiceID == id
    }

    var canUseVoicePlayback: Bool {
        !isSaving && !isVoiceCaptureBusy
    }

    func canRetryDraftVoiceTranscription(id: UUID) -> Bool {
        guard
            !isSaving,
            !isVoiceCaptureBusy,
            transcribingSavedVoiceIDs.isEmpty,
            let index = draftVoiceIndex(id: id),
            case .ready = draftVoices[index].capturePhase
        else {
            return false
        }
        return draftVoices[index].transcriptionStatus != .completed
            && !draftVoices[index].isTranscriptUserEdited
    }

    private var isVoiceCaptureBusy: Bool {
        activeDraftVoice != nil || isTranscribingDraftVoice
    }

    private var activeDraftVoice: DraftVoice? {
        draftVoices.first { draftVoice in
            switch draftVoice.capturePhase {
            case .preparing, .recording, .paused, .finalizing:
                return true
            case .ready, .failed:
                return false
            }
        }
    }

    var isImportingPhotos: Bool {
        draftPhotos.contains { photo in
            if case .importing = photo.state {
                return true
            }
            return false
        }
    }

    var remainingPhotoCapacity: Int {
        max(0, Self.maxPhotosPerEntry - draftPhotos.count)
    }

    var canAddPhoto: Bool {
        isCaptureDraftAvailable
            && !isSaving
            && !isRestoringDraft
            && !isImportingPhotos
            && !isVoiceCaptureBusy
            && remainingPhotoCapacity > 0
    }

    @discardableResult
    func beginPhotoImport() -> UUID? {
        guard
            !isSaving,
            !isRestoringDraft,
            !isVoiceCaptureBusy,
            remainingPhotoCapacity > 0
        else {
            return nil
        }
        let id = UUID()
        draftPhotos.append(
            DraftPhoto(id: id, state: .importing, annotationText: "")
        )
        scheduleDraftPersistence()
        return id
    }

    func completePhotoImport(id: UUID, photo: ImportedPhoto) {
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            Task {
                try? await photoLibrary.removePhoto(photo)
            }
            return
        }

        draftPhotos[index].state = .ready(photo)
        scheduleDraftPersistence()
    }

    func failPhotoImport(id: UUID) {
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }
        draftPhotos[index].state = .failed
        scheduleDraftPersistence()
    }

    func removeDraftPhoto(id: UUID) {
        guard !isSaving else {
            return
        }
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedPhoto = draftPhotos.remove(at: index)
        let removedVoiceIDs = draftVoices
            .filter { $0.targetPhotoID == id }
            .map(\.id)
        removeDraftVoicesFromMemory(ids: Set(removedVoiceIDs))
        persistDraftAfterRemovingPhoto(
            removedPhoto,
            removedVoiceIDs: removedVoiceIDs
        )
    }

    func updatePhotoAnnotation(id: UUID, text: String) {
        guard !isSaving else {
            return
        }
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }
        draftPhotos[index].annotationText = text
        scheduleDraftPersistence()
    }

    func startVoiceRecording() async {
        await startVoiceRecording(targetPhotoID: nil)
    }

    func startVoiceRecording(targetPhotoID: UUID?) async {
        guard canAddVoice(targetPhotoID: targetPhotoID) else {
            return
        }

        stopVoicePlayback()
        voiceGeneration += 1
        let generation = voiceGeneration
        let id = UUID()
        draftVoices.append(
            DraftVoice(
                id: id,
                targetPhotoID: targetPhotoID,
                capturePhase: .preparing,
                keepOriginalAudio: true,
                transcriptText: "",
                transcriptionStatus: .notRequested,
                transcriptionSource: nil,
                sourceLocaleIdentifier: Locale.autoupdatingCurrent.identifier,
                isTranscriptUserEdited: false
            )
        )
        voiceElapsedMilliseconds = 0
        scheduleDraftPersistence()

        let permissionGranted = await voiceRecorder.requestPermission()
        guard voiceGeneration == generation, draftVoiceIndex(id: id) != nil else {
            return
        }
        guard permissionGranted else {
            draftVoices.removeAll { $0.id == id }
            scheduleDraftPersistence()
            alert = Alert(message: VoiceRecorderError.microphonePermissionDenied.localizedDescription)
            return
        }

        do {
            let target = try await audioLibrary.prepareRecording(id: id)
            guard voiceGeneration == generation, draftVoiceIndex(id: id) != nil else {
                try? await audioLibrary.removeAudio(id: id)
                return
            }
            try voiceRecorder.startRecording(
                to: target.fileURL,
                maximumDuration: Self.maximumVoiceDuration
            )
            guard voiceGeneration == generation,
                  let index = draftVoiceIndex(id: id) else {
                voiceRecorder.stopRecording()
                try? await audioLibrary.removeAudio(id: id)
                return
            }
            draftVoices[index].capturePhase = .recording
            scheduleDraftPersistence()
            startVoiceTimer(id: id, generation: generation)
        } catch {
            voiceRecorder.cancelRecording()
            try? await audioLibrary.removeAudio(id: id)
            guard voiceGeneration == generation, draftVoiceIndex(id: id) != nil else {
                return
            }
            draftVoices.removeAll { $0.id == id }
            scheduleDraftPersistence()
            alert = Alert(message: error.localizedDescription)
        }
    }

    func pauseVoiceRecording() {
        guard let id = draftVoice?.id else {
            return
        }
        pauseVoiceRecording(id: id)
    }

    func pauseVoiceRecording(id: UUID) {
        guard let index = draftVoiceIndex(id: id),
              case .recording = draftVoices[index].capturePhase else {
            return
        }
        voiceRecorder.pauseRecording()
        voiceElapsedMilliseconds = voiceRecorder.currentDurationMilliseconds
        draftVoices[index].capturePhase = .paused
        scheduleDraftPersistence()
    }

    func resumeVoiceRecording() {
        guard let id = draftVoice?.id else {
            return
        }
        resumeVoiceRecording(id: id)
    }

    func resumeVoiceRecording(id: UUID) {
        guard let index = draftVoiceIndex(id: id),
              case .paused = draftVoices[index].capturePhase else {
            return
        }
        do {
            try voiceRecorder.resumeRecording(
                maximumDuration: Self.maximumVoiceDuration
            )
            guard let updatedIndex = draftVoiceIndex(id: id) else {
                voiceRecorder.stopRecording()
                return
            }
            draftVoices[updatedIndex].capturePhase = .recording
            scheduleDraftPersistence()
        } catch {
            alert = Alert(message: error.localizedDescription)
        }
    }

    func finishVoiceRecording() async {
        guard let id = draftVoice?.id else {
            return
        }
        await finishVoiceRecording(id: id)
    }

    func finishVoiceRecording(id: UUID) async {
        guard let index = draftVoiceIndex(id: id) else {
            return
        }
        switch draftVoices[index].capturePhase {
        case .recording, .paused:
            break
        case .preparing, .finalizing, .ready, .failed:
            return
        }

        let generation = voiceGeneration
        voiceTimerTask?.cancel()
        voiceElapsedMilliseconds = voiceRecorder.currentDurationMilliseconds
        draftVoices[index].capturePhase = .finalizing
        voiceRecorder.stopRecording()
        scheduleDraftPersistence()
        await completeVoiceRecording(
            id: id,
            generation: generation,
            startsTranscription: true
        )
    }

    func retryDraftVoiceTranscription() {
        guard let id = draftVoice?.id else {
            return
        }
        retryDraftVoiceTranscription(id: id)
    }

    func retryDraftVoiceTranscription(id: UUID) {
        guard canRetryDraftVoiceTranscription(id: id) else {
            return
        }
        beginDraftVoiceTranscription(id: id)
    }

    func retrySavedVoiceTranscription(_ voice: VoiceAttachment) {
        guard
            let relativePath = voice.originalRelativePath,
            !voice.isTranscriptUserEdited,
            transcribingSavedVoiceIDs.isEmpty,
            !isVoiceCaptureBusy
        else {
            return
        }

        savedVoiceTranscriptionGeneration += 1
        let generation = savedVoiceTranscriptionGeneration
        savedVoiceTranscriptionTask?.cancel()
        speechTranscriber.cancel()
        transcribingSavedVoiceIDs = [voice.id]

        savedVoiceTranscriptionTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.savedVoiceTranscriptionGeneration == generation {
                    self.transcribingSavedVoiceIDs.remove(voice.id)
                }
            }
            do {
                _ = try await self.workspace.updateVoiceTranscript(
                    id: voice.id,
                    userID: self.userID,
                    text: voice.transcriptText,
                    status: .pending,
                    source: nil,
                    isUserEdited: false,
                    sourceLocaleIdentifier: voice.sourceLocaleIdentifier,
                    updatedAt: self.now()
                )
                let fileURL = try await self.audioLibrary.playbackURL(
                    for: relativePath
                )
                let localeIdentifier = voice.sourceLocaleIdentifier.isEmpty
                    ? Locale.autoupdatingCurrent.identifier
                    : voice.sourceLocaleIdentifier
                let result = try await self.speechTranscriber.transcribe(
                    fileURL: fileURL,
                    localeIdentifier: localeIdentifier
                )
                guard !Task.isCancelled,
                      self.savedVoiceTranscriptionGeneration == generation else {
                    return
                }
                _ = try await self.workspace.updateVoiceTranscript(
                    id: voice.id,
                    userID: self.userID,
                    text: result.text,
                    status: .completed,
                    source: result.source.voiceTranscriptionSource,
                    isUserEdited: false,
                    sourceLocaleIdentifier: localeIdentifier,
                    updatedAt: self.now()
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.savedVoiceTranscriptionGeneration == generation else {
                    return
                }
                let status: VoiceTranscriptionStatus
                if let transcriptionError = error as? SpeechTranscriberError {
                    switch transcriptionError {
                    case .permissionDenied, .restricted:
                        status = .permissionDenied
                    case .recognizerUnavailable, .noSpeech, .recognitionFailed:
                        status = .failed
                    }
                } else {
                    status = .failed
                }
                _ = try? await self.workspace.updateVoiceTranscript(
                    id: voice.id,
                    userID: self.userID,
                    text: voice.transcriptText,
                    status: status,
                    source: nil,
                    isUserEdited: voice.isTranscriptUserEdited,
                    sourceLocaleIdentifier: voice.sourceLocaleIdentifier,
                    updatedAt: self.now()
                )
                self.alert = Alert(message: error.localizedDescription)
            }

            guard self.savedVoiceTranscriptionGeneration == generation else {
                return
            }
            await self.refreshToday(showError: false)
        }
    }

    func updateSavedVoiceTranscript(
        _ voice: VoiceAttachment,
        text: String
    ) async -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard voice.originalRelativePath != nil || !normalizedText.isEmpty else {
            alert = Alert(message: EntryValidationError.transcriptOnlyVoiceRequiresTranscript.localizedDescription)
            return false
        }

        if transcribingSavedVoiceIDs.contains(voice.id) {
            savedVoiceTranscriptionGeneration += 1
            savedVoiceTranscriptionTask?.cancel()
            speechTranscriber.cancel()
            transcribingSavedVoiceIDs.removeAll()
        }
        do {
            _ = try await workspace.updateVoiceTranscript(
                id: voice.id,
                userID: userID,
                text: normalizedText,
                status: normalizedText.isEmpty ? .notRequested : .completed,
                source: normalizedText.isEmpty ? nil : .manual,
                isUserEdited: !normalizedText.isEmpty,
                sourceLocaleIdentifier: voice.sourceLocaleIdentifier,
                updatedAt: now()
            )
            await refreshToday(showError: false)
            return true
        } catch {
            alert = Alert(message: "暂时无法保存转写修改，请稍后重试。")
            return false
        }
    }

    func skipDraftVoiceTranscription() {
        guard let id = draftVoice?.id else {
            return
        }
        skipDraftVoiceTranscription(id: id)
    }

    func skipDraftVoiceTranscription(id: UUID) {
        guard let index = draftVoiceIndex(id: id) else {
            return
        }
        if transcribingDraftVoiceID == id {
            draftVoiceTranscriptionGeneration += 1
            voiceTranscriptionTask?.cancel()
            speechTranscriber.cancel()
            transcribingDraftVoiceID = nil
        }
        if draftVoices[index].transcriptionStatus == .pending {
            draftVoices[index].transcriptionStatus = .notRequested
            draftVoices[index].transcriptionSource = nil
        }
        scheduleDraftPersistence()
    }

    func updateDraftVoiceTranscript(_ text: String) {
        guard let id = draftVoice?.id else {
            return
        }
        updateDraftVoiceTranscript(id: id, text: text)
    }

    func updateDraftVoiceTranscript(id: UUID, text: String) {
        guard let index = draftVoiceIndex(id: id), !isSaving else {
            return
        }
        if transcribingDraftVoiceID == id {
            draftVoiceTranscriptionGeneration += 1
            voiceTranscriptionTask?.cancel()
            speechTranscriber.cancel()
            transcribingDraftVoiceID = nil
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draftVoices[index].transcriptText = text
        draftVoices[index].isTranscriptUserEdited = !normalizedText.isEmpty
        draftVoices[index].transcriptionStatus = normalizedText.isEmpty
            ? .notRequested
            : .completed
        draftVoices[index].transcriptionSource = normalizedText.isEmpty ? nil : .manual
        scheduleDraftPersistence()
    }

    func setKeepOriginalAudio(_ shouldKeep: Bool) {
        guard let id = draftVoice?.id else {
            return
        }
        setKeepOriginalAudio(id: id, shouldKeep: shouldKeep)
    }

    func setKeepOriginalAudio(id: UUID, shouldKeep: Bool) {
        guard let index = draftVoiceIndex(id: id), !isSaving else {
            return
        }
        draftVoices[index].keepOriginalAudio = shouldKeep
        scheduleDraftPersistence()
    }

    func removeDraftVoice() {
        guard let id = draftVoice?.id else {
            return
        }
        removeDraftVoice(id: id)
    }

    func removeDraftVoice(id: UUID) {
        guard draftVoiceIndex(id: id) != nil, !isSaving else {
            return
        }
        removeDraftVoicesFromMemory(ids: [id])
        persistDraftAfterRemovingVoice(id: id)
    }

    func toggleVoicePlayback(id: UUID, relativePath: String) async {
        guard canUseVoicePlayback else {
            return
        }

        do {
            if playbackVoiceID == id {
                if isVoicePlaying {
                    voicePlayer.pause()
                    playbackProgressTask?.cancel()
                    isVoicePlaying = false
                } else {
                    try voicePlayer.resume()
                    isVoicePlaying = true
                    startPlaybackProgressTimer(id: id)
                }
                return
            }

            stopVoicePlayback()
            let generation = playbackGeneration
            let fileURL = try await audioLibrary.playbackURL(for: relativePath)
            guard
                playbackGeneration == generation,
                !isVoiceCaptureBusy
            else {
                return
            }
            try voicePlayer.play(fileURL: fileURL)
            playbackVoiceID = id
            isVoicePlaying = true
            voicePlaybackProgress = 0
            startPlaybackProgressTimer(id: id)
        } catch {
            stopVoicePlayback()
            alert = Alert(message: error.localizedDescription)
        }
    }

    func stopVoicePlayback() {
        playbackGeneration += 1
        playbackProgressTask?.cancel()
        voicePlayer.stop()
        playbackVoiceID = nil
        isVoicePlaying = false
        voicePlaybackProgress = 0
    }

    func handleSceneDeactivation(isEnteringBackground: Bool) {
        stopVoicePlayback()

        guard let activeVoice = activeDraftVoice else {
            Task { [weak self] in
                await self?.flushCaptureDraft()
            }
            return
        }
        switch activeVoice.capturePhase {
        case .recording, .paused:
            let id = activeVoice.id
            let generation = voiceGeneration
            voiceTimerTask?.cancel()
            voiceElapsedMilliseconds = voiceRecorder.currentDurationMilliseconds
            if let index = draftVoiceIndex(id: id) {
                draftVoices[index].capturePhase = .finalizing
            }
            voiceRecorder.stopRecording()
            scheduleDraftPersistence()
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.completeVoiceRecording(
                    id: id,
                    generation: generation,
                    startsTranscription: false
                )
                await self.flushCaptureDraft()
            }
        case .preparing where isEnteringBackground:
            let id = activeVoice.id
            voiceGeneration += 1
            draftVoices.removeAll { $0.id == id }
            voiceElapsedMilliseconds = 0
            scheduleDraftPersistence()
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.flushCaptureDraft()
                try? await self.audioLibrary.removeAudio(id: id)
            }
        case .preparing, .finalizing, .ready, .failed:
            Task { [weak self] in
                await self?.flushCaptureDraft()
            }
        }
    }

    private func handleVoiceRecordingInterruption() {
        guard let activeVoice = activeDraftVoice else {
            return
        }
        switch activeVoice.capturePhase {
        case .recording, .paused:
            let id = activeVoice.id
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.finishVoiceRecording(id: id)
                if let index = self.draftVoiceIndex(id: id),
                   case .ready = self.draftVoices[index].capturePhase {
                    self.alert = Alert(message: "录音因系统中断而停止，已保留当前内容。")
                }
            }
        case .preparing, .finalizing, .ready, .failed:
            break
        }
    }

    func showCapture() {
        stopVoicePlayback()
        route = .capture
    }

    func showToday() {
        guard activeDraftVoice == nil else {
            alert = Alert(message: "请先结束当前录音，再查看今天。")
            return
        }
        guard !isTranscribingDraftVoice else {
            alert = Alert(message: "请等待转写完成，或先跳过转写。")
            return
        }
        stopVoicePlayback()
        route = .today
        Task { [weak self] in
            await self?.refreshToday()
        }
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard isCaptureDraftAvailable else {
            alert = Alert(message: "草稿暂时无法读取。为避免覆盖原内容，请重新打开 App 后再试。")
            return false
        }
        guard !isSaving else {
            return false
        }
        stopVoicePlayback()

        let photos: [NewPhotoAttachment]
        do {
            photos = try draftPhotos.map { draftPhoto in
                guard case let .ready(photo) = draftPhoto.state else {
                    throw EntryValidationError.emptyEntry
                }
                return NewPhotoAttachment(
                    id: photo.id,
                    annotationText: draftPhoto.annotationText,
                    contentTypeIdentifier: photo.contentTypeIdentifier,
                    pixelWidth: photo.pixelWidth,
                    pixelHeight: photo.pixelHeight,
                    byteCount: photo.byteCount,
                    originalRelativePath: photo.originalRelativePath,
                    thumbnailRelativePath: photo.thumbnailRelativePath
                )
            }
        } catch {
            alert = Alert(message: "请先移除导入失败的照片，或等待照片导入完成。")
            return false
        }

        guard !isTranscribingDraftVoice else {
            alert = Alert(message: "请等待转写完成，或先跳过转写再保存。")
            return false
        }

        var voices: [NewVoiceAttachment] = []
        var transcriptOnlyAudioIDs: [UUID] = []
        for draftVoice in draftVoices {
            guard case let .ready(audio) = draftVoice.capturePhase else {
                alert = Alert(message: "请先结束录音，或移除无法读取的录音。")
                return false
            }
            let keepsOriginalAudio = draftVoice.keepOriginalAudio
            voices.append(
                NewVoiceAttachment(
                    id: draftVoice.id,
                    targetPhotoID: draftVoice.targetPhotoID,
                    durationMilliseconds: audio.durationMilliseconds,
                    contentTypeIdentifier: keepsOriginalAudio
                        ? audio.contentTypeIdentifier
                        : nil,
                    byteCount: keepsOriginalAudio ? audio.byteCount : 0,
                    originalRelativePath: keepsOriginalAudio
                        ? audio.relativePath
                        : nil,
                    transcriptText: draftVoice.transcriptText,
                    transcriptionStatus: draftVoice.transcriptionStatus,
                    transcriptionSource: draftVoice.transcriptionSource,
                    sourceLocaleIdentifier: draftVoice.sourceLocaleIdentifier,
                    isTranscriptUserEdited: draftVoice.isTranscriptUserEdited
                )
            )
            if !keepsOriginalAudio {
                transcriptOnlyAudioIDs.append(draftVoice.id)
            }
        }

        let draft: NewEntry
        do {
            draft = try NewEntry(
                sourceDraftID: captureDraftID,
                text: draftText,
                photos: photos,
                voices: voices
            )
        } catch {
            alert = Alert(message: error.localizedDescription)
            return false
        }

        isSaving = true
        defer { isSaving = false }

        let recordingContext = RecordingContext(
            instant: now(),
            timeZone: currentTimeZone()
        )

        let entry: Entry
        do {
            entry = try await workspace.create(
                draft,
                userID: userID,
                context: recordingContext
            )
        } catch {
            alert = Alert(message: "暂时无法保存这条记录。内容仍在这里，请稍后重试。")
            return false
        }

        let displayedDayKey = DayKey(containing: todayDate, in: todayTimeZone)
        if displayedDayKey == entry.dayKey {
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
        } else {
            entries = [entry]
        }
        todayDate = recordingContext.instant
        todayTimeZone = recordingContext.timeZone
        clearCaptureDraftInMemory()
        var didDereferenceCaptureDraft = false
        if canPersistCaptureDraft {
            do {
                try await captureDraftStore.clear()
                didDereferenceCaptureDraft = true
            } catch {
                alert = Alert(message: "记录已保存，但暂时无法清理本地草稿。")
            }
        }
        if didDereferenceCaptureDraft {
            for id in transcriptOnlyAudioIDs {
                await removeAudioIfUnreferenced(id: id)
            }
        }
        route = .today
        showNotice("已保存到今天")

        await refreshToday(showError: false)
        return true
    }

    func refreshToday(showError: Bool = true) async {
        let date = now()
        let timeZone = currentTimeZone()
        let dayKey = DayKey(containing: date, in: timeZone)

        isLoadingToday = true
        defer { isLoadingToday = false }

        do {
            entries = try await workspace.entries(for: dayKey, userID: userID)
            todayDate = date
            todayTimeZone = timeZone
        } catch {
            if showError {
                alert = Alert(message: "暂时无法读取今天的记录，请稍后重试。")
            }
        }
    }

    func flushCaptureDraft() async {
        guard !isRestoringDraft, canPersistCaptureDraft else {
            return
        }

        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        let snapshot = captureDraftSnapshot
        draftPersistenceTask?.cancel()
        _ = await persistCaptureDraft(snapshot, generation: generation)
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.notice = nil
        }
    }

    private func restoreCaptureDraft() async -> Bool {
        var shouldSchedulePersistence = true
        defer {
            isRestoringDraft = false
            if shouldSchedulePersistence {
                scheduleDraftPersistence()
            }
        }

        let snapshot: CaptureDraftSnapshot
        do {
            guard let loadedSnapshot = try await captureDraftStore.load() else {
                return true
            }
            snapshot = loadedSnapshot
        } catch {
            shouldSchedulePersistence = false
            canPersistCaptureDraft = false
            isCaptureDraftAvailable = false
            alert = Alert(message: "上次未保存的草稿暂时无法读取。为避免覆盖原内容，当前记录已暂停，请重新打开 App 后再试。")
            return false
        }

        do {
            if try await workspace.hasCommittedDraft(id: snapshot.id, userID: userID) {
                do {
                    try await captureDraftStore.clear()
                } catch {
                    alert = Alert(message: "记录已保存，但暂时无法清理本地草稿。")
                }
                return true
            }
        } catch {
            alert = Alert(message: "暂时无法确认上次草稿是否已保存，请先核对今天的记录。")
        }

        guard Self.hasValidVoiceLayout(in: snapshot) else {
            shouldSchedulePersistence = false
            canPersistCaptureDraft = false
            isCaptureDraftAvailable = false
            alert = Alert(
                message: "上次草稿包含无法安全恢复的语音批注。为避免丢失内容，当前记录已暂停，请保留草稿并稍后处理。"
            )
            return false
        }

        suppressDraftPersistence = true
        captureDraftID = snapshot.id
        draftText = snapshot.text
        draftPhotos = snapshot.photos.map(Self.draftPhoto(from:))
        for voiceSnapshot in snapshot.voices {
            draftVoices.append(await restoreDraftVoice(from: voiceSnapshot))
        }
        if let globalVoice = draftVoice,
           case let .ready(audio) = globalVoice.capturePhase {
            voiceElapsedMilliseconds = audio.durationMilliseconds
        }
        suppressDraftPersistence = false
        return true
    }

    private func scheduleDraftPersistence() {
        guard canPersistCaptureDraft,
              !suppressDraftPersistence,
              !isRestoringDraft else {
            return
        }

        let snapshot = captureDraftSnapshot
        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  self?.draftPersistenceGeneration == generation else {
                return
            }
            _ = await self?.persistCaptureDraft(snapshot, generation: generation)
        }
    }

    private func persistCaptureDraft(
        _ snapshot: CaptureDraftSnapshot,
        generation: Int
    ) async -> Bool {
        guard canPersistCaptureDraft,
              !Task.isCancelled,
              generation == draftPersistenceGeneration else {
            return false
        }
        do {
            if snapshot.text.isEmpty && snapshot.photos.isEmpty && snapshot.voices.isEmpty {
                try await captureDraftStore.clear()
            } else {
                try await captureDraftStore.save(snapshot)
            }
            guard !Task.isCancelled, generation == draftPersistenceGeneration else {
                return false
            }
            reportedDraftPersistenceError = false
            return true
        } catch {
            guard !reportedDraftPersistenceError else {
                return false
            }
            reportedDraftPersistenceError = true
            alert = Alert(message: "草稿暂时无法写入本地，请尽快保存记录。")
            return false
        }
    }

    private var captureDraftSnapshot: CaptureDraftSnapshot {
        CaptureDraftSnapshot(
            id: captureDraftID,
            text: draftText,
            photos: draftPhotos.map(Self.snapshot(from:)),
            voices: draftVoices.map(Self.snapshot(from:))
        )
    }

    private func clearCaptureDraftInMemory() {
        draftPersistenceGeneration += 1
        draftPersistenceTask?.cancel()
        voiceGeneration += 1
        draftVoiceTranscriptionGeneration += 1
        voiceTimerTask?.cancel()
        voiceTranscriptionTask?.cancel()
        if isTranscribingDraftVoice {
            speechTranscriber.cancel()
        }
        voiceRecorder.stopRecording()
        suppressDraftPersistence = true
        draftText = ""
        draftPhotos = []
        draftVoices = []
        voiceElapsedMilliseconds = 0
        transcribingDraftVoiceID = nil
        captureDraftID = UUID()
        suppressDraftPersistence = false
    }

    private func reconcilePhotoStorage() async {
        do {
            var referencedIDs = try await workspace.allPhotoIDs()
            for draftPhoto in draftPhotos {
                if case let .ready(photo) = draftPhoto.state {
                    referencedIDs.insert(photo.id)
                }
            }
            try await photoLibrary.removeUnreferencedPhotos(
                keeping: referencedIDs,
                olderThan: Date().addingTimeInterval(-3_600)
            )
        } catch {
            // 媒体清理失败不应阻断记录与读取，后续启动会再次尝试。
        }
    }

    private func reconcileAudioStorage() async {
        do {
            var referencedIDs = try await workspace.allRetainedVoiceIDs()
            referencedIDs.formUnion(draftVoices.map(\.id))
            try await audioLibrary.removeUnreferencedAudio(
                keeping: referencedIDs,
                olderThan: Date().addingTimeInterval(-3_600)
            )
        } catch {
            // 音频清理失败不应阻断记录与读取，后续启动会再次尝试。
        }
    }

    private func draftVoiceIndex(id: UUID) -> Int? {
        draftVoices.firstIndex { $0.id == id }
    }

    private func removeDraftVoicesFromMemory(ids: Set<UUID>) {
        guard !ids.isEmpty else {
            return
        }

        if let activeVoiceID = activeDraftVoice?.id,
           ids.contains(activeVoiceID) {
            voiceGeneration += 1
            voiceTimerTask?.cancel()
            voiceRecorder.cancelRecording()
            voiceElapsedMilliseconds = 0
        }
        if let transcribingDraftVoiceID,
           ids.contains(transcribingDraftVoiceID) {
            draftVoiceTranscriptionGeneration += 1
            voiceTranscriptionTask?.cancel()
            speechTranscriber.cancel()
            self.transcribingDraftVoiceID = nil
        }
        if let playbackVoiceID, ids.contains(playbackVoiceID) {
            stopVoicePlayback()
        }
        draftVoices.removeAll { ids.contains($0.id) }
    }

    private func startVoiceTimer(id: UUID, generation: Int) {
        voiceTimerTask?.cancel()
        voiceTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else {
                    return
                }
                guard self.voiceGeneration == generation,
                      let index = self.draftVoiceIndex(id: id) else {
                    return
                }

                let elapsed = min(
                    self.voiceRecorder.currentDurationMilliseconds,
                    Int(Self.maximumVoiceDuration * 1_000)
                )
                self.voiceElapsedMilliseconds = elapsed

                guard case .recording = self.draftVoices[index].capturePhase else {
                    continue
                }
                if !self.voiceRecorder.isRecording
                    || elapsed >= Int(Self.maximumVoiceDuration * 1_000) {
                    await self.finishVoiceRecording(id: id)
                    return
                }
            }
        }
    }

    private func completeVoiceRecording(
        id: UUID,
        generation: Int,
        startsTranscription: Bool
    ) async {
        do {
            let audio = try await audioLibrary.completeRecording(id: id)
            guard voiceGeneration == generation,
                  let index = draftVoiceIndex(id: id) else {
                return
            }
            draftVoices[index].capturePhase = .ready(audio)
            voiceElapsedMilliseconds = audio.durationMilliseconds
            scheduleDraftPersistence()
            if startsTranscription {
                beginDraftVoiceTranscription(id: id)
            }
        } catch {
            guard voiceGeneration == generation,
                  let index = draftVoiceIndex(id: id) else {
                return
            }
            draftVoices[index].capturePhase = .failed
            scheduleDraftPersistence()
            alert = Alert(message: "录音已停止，但文件无法读取。请移除后重新录制。")
        }
    }

    private func beginDraftVoiceTranscription(id: UUID) {
        guard
            !isSaving,
            !isTranscribingDraftVoice,
            activeDraftVoice == nil,
            let index = draftVoiceIndex(id: id)
        else {
            return
        }
        let draftVoice = draftVoices[index]
        guard
            case let .ready(audio) = draftVoice.capturePhase,
            !draftVoice.isTranscriptUserEdited
                || draftVoice.transcriptText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        else {
            return
        }
        guard transcribingSavedVoiceIDs.isEmpty else {
            if let currentIndex = draftVoiceIndex(id: id) {
                draftVoices[currentIndex].transcriptionStatus = .notRequested
            }
            scheduleDraftPersistence()
            alert = Alert(message: "另一段录音正在转写，请稍后重试。")
            return
        }

        stopVoicePlayback()

        draftVoiceTranscriptionGeneration += 1
        let generation = draftVoiceTranscriptionGeneration
        let voiceID = draftVoice.id
        let localeIdentifier = draftVoice.sourceLocaleIdentifier.isEmpty
            ? Locale.autoupdatingCurrent.identifier
            : draftVoice.sourceLocaleIdentifier
        voiceTranscriptionTask?.cancel()
        speechTranscriber.cancel()
        transcribingDraftVoiceID = voiceID
        draftVoices[index].transcriptionStatus = .pending
        draftVoices[index].transcriptionSource = nil
        draftVoices[index].sourceLocaleIdentifier = localeIdentifier
        scheduleDraftPersistence()

        voiceTranscriptionTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let fileURL = try await self.audioLibrary.playbackURL(
                    for: audio.relativePath
                )
                let result = try await self.speechTranscriber.transcribe(
                    fileURL: fileURL,
                    localeIdentifier: localeIdentifier
                )
                guard !Task.isCancelled,
                      self.draftVoiceTranscriptionGeneration == generation,
                      self.transcribingDraftVoiceID == voiceID,
                      let currentIndex = self.draftVoiceIndex(id: voiceID),
                      self.draftVoices[currentIndex].isTranscriptUserEdited == false else {
                    return
                }
                self.draftVoices[currentIndex].transcriptText = result.text
                self.draftVoices[currentIndex].transcriptionStatus = .completed
                self.draftVoices[currentIndex].transcriptionSource =
                    result.source.voiceTranscriptionSource
                self.transcribingDraftVoiceID = nil
                self.scheduleDraftPersistence()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.draftVoiceTranscriptionGeneration == generation,
                      self.transcribingDraftVoiceID == voiceID,
                      let currentIndex = self.draftVoiceIndex(id: voiceID) else {
                    return
                }
                self.transcribingDraftVoiceID = nil
                if let transcriptionError = error as? SpeechTranscriberError {
                    switch transcriptionError {
                    case .permissionDenied, .restricted:
                        self.draftVoices[currentIndex].transcriptionStatus = .permissionDenied
                    case .recognizerUnavailable, .noSpeech, .recognitionFailed:
                        self.draftVoices[currentIndex].transcriptionStatus = .failed
                    }
                } else {
                    self.draftVoices[currentIndex].transcriptionStatus = .failed
                }
                self.draftVoices[currentIndex].transcriptionSource = nil
                self.scheduleDraftPersistence()
                self.alert = Alert(message: error.localizedDescription)
            }
        }
    }

    private func startPlaybackProgressTimer(id: UUID) {
        playbackGeneration += 1
        let generation = playbackGeneration
        playbackProgressTask?.cancel()
        playbackProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else {
                    return
                }
                guard self.playbackGeneration == generation,
                      self.playbackVoiceID == id else {
                    return
                }
                let duration = self.voicePlayer.durationMilliseconds
                let current = self.voicePlayer.currentTimeMilliseconds
                self.voicePlaybackProgress = duration > 0
                    ? min(1, max(0, Double(current) / Double(duration)))
                    : 0
                if !self.voicePlayer.isPlaying {
                    self.stopVoicePlayback()
                    return
                }
            }
        }
    }

    private func restoreDraftVoice(
        from snapshot: CaptureDraftVoiceSnapshot
    ) async -> DraftVoice {
        let capturePhase: DraftVoice.CapturePhase
        do {
            let audio = try await audioLibrary.completeRecording(id: snapshot.id)
            capturePhase = .ready(audio)
        } catch {
            capturePhase = .failed
        }
        let transcriptionStatus = snapshot.transcriptionStatus == .pending
            ? VoiceTranscriptionStatus.failed
            : snapshot.transcriptionStatus

        return DraftVoice(
            id: snapshot.id,
            targetPhotoID: snapshot.targetPhotoID,
            capturePhase: capturePhase,
            keepOriginalAudio: snapshot.keepOriginalAudio,
            transcriptText: snapshot.transcriptText,
            transcriptionStatus: transcriptionStatus,
            transcriptionSource: snapshot.transcriptionSource,
            sourceLocaleIdentifier: snapshot.sourceLocaleIdentifier,
            isTranscriptUserEdited: snapshot.isTranscriptUserEdited
        )
    }

    private func persistDraftAfterRemovingVoice(id: UUID) {
        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        let snapshot = captureDraftSnapshot
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didPersist = await self.persistCaptureDraft(
                snapshot,
                generation: generation
            )
            guard didPersist,
                  !Task.isCancelled,
                  self.draftPersistenceGeneration == generation else {
                return
            }
            await self.removeAudioIfUnreferenced(id: id)
        }
    }

    private func removeAudioIfUnreferenced(id: UUID) async {
        do {
            guard !draftVoices.contains(where: { $0.id == id }) else {
                return
            }
            let retainedVoiceIDs = try await workspace.allRetainedVoiceIDs()
            guard !retainedVoiceIDs.contains(id) else {
                return
            }
            try await audioLibrary.removeAudio(id: id)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            alert = Alert(message: "暂时无法清理这段录音，请稍后重试。")
        }
    }

    private func persistDraftAfterRemovingPhoto(
        _ removedPhoto: DraftPhoto,
        removedVoiceIDs: [UUID]
    ) {
        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        let snapshot = captureDraftSnapshot
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didPersist = await self.persistCaptureDraft(snapshot, generation: generation)
            guard didPersist,
                  !Task.isCancelled,
                  self.draftPersistenceGeneration == generation else {
                return
            }

            for voiceID in removedVoiceIDs {
                await self.removeAudioIfUnreferenced(id: voiceID)
            }

            guard case let .ready(photo) = removedPhoto.state else {
                return
            }

            do {
                let referencedPhotoIDs = try await self.workspace.allPhotoIDs()
                guard !Task.isCancelled,
                      self.draftPersistenceGeneration == generation,
                      !referencedPhotoIDs.contains(photo.id) else {
                    return
                }
                try await self.photoLibrary.removePhoto(photo)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.alert = Alert(message: "暂时无法清理这张照片，请稍后重试。")
            }
        }
    }

    private static func snapshot(
        from draftVoice: DraftVoice
    ) -> CaptureDraftVoiceSnapshot {
        let captureState: CaptureDraftVoiceSnapshot.CaptureState
        switch draftVoice.capturePhase {
        case .preparing, .recording, .finalizing:
            captureState = .recording
        case .paused:
            captureState = .paused
        case .ready:
            captureState = .ready
        case .failed:
            captureState = .failed
        }

        return CaptureDraftVoiceSnapshot(
            id: draftVoice.id,
            targetPhotoID: draftVoice.targetPhotoID,
            captureState: captureState,
            keepOriginalAudio: draftVoice.keepOriginalAudio,
            transcriptText: draftVoice.transcriptText,
            transcriptionStatus: draftVoice.transcriptionStatus,
            transcriptionSource: draftVoice.transcriptionSource,
            sourceLocaleIdentifier: draftVoice.sourceLocaleIdentifier,
            isTranscriptUserEdited: draftVoice.isTranscriptUserEdited
        )
    }

    private static func hasValidVoiceLayout(
        in snapshot: CaptureDraftSnapshot
    ) -> Bool {
        let photoIDs = Set(snapshot.photos.map(\.id))
        var voiceIDs: Set<UUID> = []
        var photoTargets: Set<UUID> = []
        var hasGlobalVoice = false

        for voice in snapshot.voices {
            guard voiceIDs.insert(voice.id).inserted else {
                return false
            }
            if let targetPhotoID = voice.targetPhotoID {
                guard
                    photoIDs.contains(targetPhotoID),
                    photoTargets.insert(targetPhotoID).inserted
                else {
                    return false
                }
            } else {
                guard !hasGlobalVoice else {
                    return false
                }
                hasGlobalVoice = true
            }
        }
        return true
    }

    private static func snapshot(from draftPhoto: DraftPhoto) -> CaptureDraftPhotoSnapshot {
        let status: CaptureDraftPhotoSnapshot.Status
        let mediaMetadata: CaptureDraftPhotoSnapshot.MediaMetadata?

        switch draftPhoto.state {
        case .importing:
            status = .importing
            mediaMetadata = nil
        case .failed:
            status = .failed
            mediaMetadata = nil
        case let .ready(photo):
            status = .ready
            mediaMetadata = CaptureDraftPhotoSnapshot.MediaMetadata(
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        }

        return CaptureDraftPhotoSnapshot(
            id: draftPhoto.id,
            status: status,
            annotationText: draftPhoto.annotationText,
            mediaMetadata: mediaMetadata
        )
    }

    private static func draftPhoto(from snapshot: CaptureDraftPhotoSnapshot) -> DraftPhoto {
        let state: DraftPhoto.State
        if snapshot.status == .ready, let metadata = snapshot.mediaMetadata {
            state = .ready(
                ImportedPhoto(
                    id: snapshot.id,
                    contentTypeIdentifier: metadata.contentTypeIdentifier,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    byteCount: metadata.byteCount,
                    originalRelativePath: metadata.originalRelativePath,
                    thumbnailRelativePath: metadata.thumbnailRelativePath
                )
            )
        } else {
            state = .failed
        }

        return DraftPhoto(
            id: snapshot.id,
            state: state,
            annotationText: snapshot.annotationText
        )
    }
}

private extension SpeechRecognitionSource {
    var voiceTranscriptionSource: VoiceTranscriptionSource {
        switch self {
        case .onDevice:
            return .onDevice
        case .network:
            return .appleNetwork
        }
    }
}
