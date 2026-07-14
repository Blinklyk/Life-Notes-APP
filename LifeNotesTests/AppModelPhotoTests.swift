import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class AppModelPhotoTests: XCTestCase {
    func testRestoreDraftPreservesTextReadyPhotoAndAnnotationAndMarksInterruptedImportFailed() async throws {
        let readyPhoto = makeImportedPhoto(
            id: UUID(uuidString: "D0DDCF8C-7237-4726-AB0B-8FB1E313A4BE")!
        )
        let importingID = UUID(uuidString: "ED6302C4-7337-4B78-8D61-F22B15C0B16C")!
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "上次没有保存完的文字",
                photos: [
                    makeReadySnapshot(photo: readyPhoto, annotationText: "傍晚的云"),
                    CaptureDraftPhotoSnapshot(
                        id: importingID,
                        status: .importing,
                        annotationText: "导入时写下的批注"
                    )
                ]
            )
        )
        let model = makeModel(captureDraftStore: store)

        await waitForDraftRestoration(model)

        XCTAssertEqual(model.draftText, "上次没有保存完的文字")
        XCTAssertEqual(model.draftPhotos.count, 2)
        XCTAssertEqual(
            model.draftPhotos[0],
            AppModel.DraftPhoto(
                id: readyPhoto.id,
                state: .ready(readyPhoto),
                annotationText: "傍晚的云"
            )
        )
        XCTAssertEqual(
            model.draftPhotos[1],
            AppModel.DraftPhoto(
                id: importingID,
                state: .failed,
                annotationText: "导入时写下的批注"
            )
        )
        XCTAssertFalse(model.isImportingPhotos)
        XCTAssertFalse(model.canSaveDraft)
    }

    func testRestoreClearsDraftAlreadyCommittedForCurrentUser() async {
        let sourceDraftID = UUID(uuidString: "2F964C08-06A3-44A3-98A3-7A97A25DBCD7")!
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                id: sourceDraftID,
                text: "已经提交但尚未清理的草稿",
                photos: []
            )
        )
        let workspace = FakeDayWorkspace(committedDraftIDs: [sourceDraftID])
        let model = makeModel(workspace: workspace, captureDraftStore: store)

        await waitForDraftRestoration(model)
        let persistedSnapshot = await store.persistedSnapshot()
        let clearCallCount = await store.clearCallCount()

        XCTAssertTrue(model.draftText.isEmpty)
        XCTAssertTrue(model.draftPhotos.isEmpty)
        XCTAssertNil(persistedSnapshot)
        XCTAssertGreaterThanOrEqual(clearCallCount, 1)
    }

    func testDraftLoadFailurePreservesStoredSnapshotAndSkipsMediaReconciliation() async {
        let photo = makeImportedPhoto()
        let snapshot = CaptureDraftSnapshot(
            text: "暂时无法读取的草稿",
            photos: [makeReadySnapshot(photo: photo, annotationText: "不能被清理")]
        )
        let store = FakeCaptureDraftStore(
            snapshot: snapshot,
            shouldFailLoad: true
        )
        let photoLibrary = FakePhotoLibrary()
        let model = makeModel(
            photoLibrary: photoLibrary,
            captureDraftStore: store
        )

        await waitForDraftRestoration(model)
        model.draftText = "不能覆盖故障草稿的新内容"
        await model.flushCaptureDraft()

        let persistedSnapshot = await store.persistedSnapshot()
        let clearCallCount = await store.clearCallCount()
        let saveCallCount = await store.saveCallCount()
        let reconciliationCallCount = await photoLibrary.reconciliationCallCount()

        XCTAssertEqual(persistedSnapshot, snapshot)
        XCTAssertEqual(clearCallCount, 0)
        XCTAssertEqual(saveCallCount, 0)
        XCTAssertEqual(reconciliationCallCount, 0)
        XCTAssertFalse(model.isCaptureDraftAvailable)
        XCTAssertFalse(model.canSaveDraft)
        XCTAssertFalse(model.canAddPhoto)
        XCTAssertEqual(
            model.alert?.message,
            "上次未保存的草稿暂时无法读取。为避免覆盖原内容，当前记录已暂停，请重新打开 App 后再试。"
        )
    }

    func testFlushCaptureDraftPersistsLatestTextPhotoAndAnnotationImmediately() async {
        let store = FakeCaptureDraftStore()
        let model = makeModel(captureDraftStore: store)
        await waitForDraftRestoration(model)

        model.draftText = "刚写完就切到后台"
        guard let importID = model.beginPhotoImport() else {
            XCTFail("应允许开始图片导入")
            return
        }
        let photo = makeImportedPhoto(id: importID)
        model.completePhotoImport(id: importID, photo: photo)
        model.updatePhotoAnnotation(id: importID, text: "刚补完的批注")

        await model.flushCaptureDraft()
        let persistedSnapshot = await store.persistedSnapshot()

        XCTAssertEqual(persistedSnapshot?.text, "刚写完就切到后台")
        XCTAssertEqual(persistedSnapshot?.photos.count, 1)
        XCTAssertEqual(persistedSnapshot?.photos.first?.id, photo.id)
        XCTAssertEqual(persistedSnapshot?.photos.first?.status, .ready)
        XCTAssertEqual(persistedSnapshot?.photos.first?.annotationText, "刚补完的批注")
    }

    func testBeginPhotoImportCapsSingleBatchAtTwentyPhotos() async {
        let model = makeModel()
        await waitForDraftRestoration(model)

        let acceptedIDs = (0..<AppModel.maxPhotosPerEntry).compactMap { _ in
            model.beginPhotoImport()
        }
        let rejectedID = model.beginPhotoImport()

        XCTAssertEqual(acceptedIDs.count, AppModel.maxPhotosPerEntry)
        XCTAssertEqual(Set(acceptedIDs).count, AppModel.maxPhotosPerEntry)
        XCTAssertNil(rejectedID)
        XCTAssertEqual(model.draftPhotos.count, AppModel.maxPhotosPerEntry)
        XCTAssertEqual(model.remainingPhotoCapacity, 0)
    }

    func testSaveRemainsSuccessfulAndCannotDuplicateWhenPostCreateRefreshFails() async {
        let workspace = FakeDayWorkspace(shouldFailEntries: true)
        let store = FakeCaptureDraftStore()
        let model = makeModel(
            workspace: workspace,
            captureDraftStore: store
        )
        await waitForDraftRestoration(model)
        model.draftText = "只能创建一次的记录"

        let firstResult = await model.saveDraft()
        let secondResult = await model.saveDraft()
        let createCallCount = await workspace.createCallCount()
        let persistedSnapshot = await store.persistedSnapshot()

        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(model.route, .today)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.text, "只能创建一次的记录")
        XCTAssertTrue(model.draftText.isEmpty)
        XCTAssertTrue(model.draftPhotos.isEmpty)
        XCTAssertNil(persistedSnapshot)
    }

    func testSuccessfulSaveClearsCaptureDraftStore() async throws {
        let sourceDraftID = UUID(uuidString: "624BC170-9E5A-41EA-B7D6-492241BA08D5")!
        let readyPhoto = makeImportedPhoto(
            id: UUID(uuidString: "E0A0844F-C2DD-4F41-B5A2-B5DECB4FF529")!
        )
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                id: sourceDraftID,
                text: "准备保存的草稿",
                photos: [makeReadySnapshot(photo: readyPhoto, annotationText: "河边散步")]
            )
        )
        let workspace = FakeDayWorkspace()
        let model = makeModel(
            workspace: workspace,
            captureDraftStore: store
        )
        await waitForDraftRestoration(model)

        let result = await model.saveDraft()
        let clearCallCount = await store.clearCallCount()
        let persistedSnapshot = await store.persistedSnapshot()
        let createdDrafts = await workspace.createdDrafts()

        XCTAssertTrue(result)
        XCTAssertEqual(clearCallCount, 1)
        XCTAssertNil(persistedSnapshot)
        XCTAssertEqual(createdDrafts.count, 1)
        XCTAssertEqual(createdDrafts.first?.sourceDraftID, sourceDraftID)
        XCTAssertEqual(createdDrafts.first?.text, "准备保存的草稿")
        XCTAssertEqual(createdDrafts.first?.photos.first?.id, readyPhoto.id)
        XCTAssertEqual(createdDrafts.first?.photos.first?.annotationText, "河边散步")
    }

    func testRemovingReadyPhotoPersistsDereferenceBeforeDeletingMedia() async {
        let operationLog = FakeOperationLog()
        let photo = makeImportedPhoto()
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "保留这段文字",
                photos: [makeReadySnapshot(photo: photo, annotationText: "待移除")]
            ),
            operationLog: operationLog
        )
        let photoLibrary = FakePhotoLibrary(operationLog: operationLog)
        let model = makeModel(
            photoLibrary: photoLibrary,
            captureDraftStore: store
        )
        await waitForDraftRestoration(model)

        model.removeDraftPhoto(id: photo.id)
        await waitUntil { await photoLibrary.wasRemoved(photo.id) }
        let persistedPhotos = await store.persistedSnapshot()?.photos

        XCTAssertEqual(persistedPhotos, [])
        let events = await operationLog.allEvents()
        let saveIndex = events.firstIndex(of: "draft.save")
        let removeIndex = events.firstIndex(of: "photo.remove")
        XCTAssertNotNil(saveIndex)
        XCTAssertNotNil(removeIndex)
        if let saveIndex, let removeIndex {
            XCTAssertLessThan(saveIndex, removeIndex)
        }
    }

    func testRemovingReadyPhotoDoesNotDeleteMediaWhenDraftPersistenceFails() async {
        let photo = makeImportedPhoto()
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "保留这段文字",
                photos: [makeReadySnapshot(photo: photo, annotationText: "待移除")]
            ),
            shouldFailSave: true
        )
        let photoLibrary = FakePhotoLibrary()
        let model = makeModel(
            photoLibrary: photoLibrary,
            captureDraftStore: store
        )
        await waitForDraftRestoration(model)

        model.removeDraftPhoto(id: photo.id)
        await waitUntil { await store.saveCallCount() >= 1 }
        let wasRemoved = await photoLibrary.wasRemoved(photo.id)

        XCTAssertFalse(wasRemoved)
        XCTAssertEqual(model.alert?.message, "草稿暂时无法写入本地，请尽快保存记录。")
    }

    func testRemovingReadyPhotoKeepsMediaReferencedByAnotherUser() async {
        let photo = makeImportedPhoto()
        let workspace = FakeDayWorkspace(externalPhotoIDs: [photo.id])
        let store = FakeCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "保留这段文字",
                photos: [makeReadySnapshot(photo: photo, annotationText: "待移除")]
            )
        )
        let photoLibrary = FakePhotoLibrary()
        let model = makeModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            captureDraftStore: store
        )
        await waitForDraftRestoration(model)
        await waitUntil { await workspace.allPhotoIDsCallCount() >= 1 }
        let callsBeforeRemoval = await workspace.allPhotoIDsCallCount()

        model.removeDraftPhoto(id: photo.id)
        await waitUntil {
            await workspace.allPhotoIDsCallCount() > callsBeforeRemoval
        }
        let persistedPhotos = await store.persistedSnapshot()?.photos
        let wasRemoved = await photoLibrary.wasRemoved(photo.id)

        XCTAssertEqual(persistedPhotos, [])
        XCTAssertFalse(wasRemoved)
    }

    func testReconciliationKeepsPhotosReferencedByAnyUser() async {
        let otherUsersPhotoID = UUID(uuidString: "FEF4470A-C9CC-485A-A79B-B3C23C411D4A")!
        let workspace = FakeDayWorkspace(externalPhotoIDs: [otherUsersPhotoID])
        let photoLibrary = FakePhotoLibrary()
        let model = makeModel(workspace: workspace, photoLibrary: photoLibrary)

        await waitForDraftRestoration(model)
        await waitUntil { await photoLibrary.reconciliationCallCount() >= 1 }
        let keepSet = await photoLibrary.lastReconciliationKeepSet()

        XCTAssertEqual(keepSet, [otherUsersPhotoID])
    }

    private func makeModel(
        workspace: FakeDayWorkspace = FakeDayWorkspace(),
        photoLibrary: FakePhotoLibrary = FakePhotoLibrary(),
        audioLibrary: FakeAudioLibrary = FakeAudioLibrary(),
        captureDraftStore: FakeCaptureDraftStore = FakeCaptureDraftStore(),
        voiceRecorder: FakeVoiceRecorder? = nil,
        speechTranscriber: FakeSpeechTranscriber? = nil,
        voicePlayer: FakeVoicePlayer? = nil
    ) -> AppModel {
        let userID = UUID(uuidString: "FD093DFD-8B78-4D4C-92F0-C7CF83928073")!
        let date = Date(timeIntervalSince1970: 1_768_435_200)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!

        return AppModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary,
            captureDraftStore: captureDraftStore,
            voiceRecorder: voiceRecorder ?? FakeVoiceRecorder(),
            speechTranscriber: speechTranscriber ?? FakeSpeechTranscriber(),
            voicePlayer: voicePlayer ?? FakeVoicePlayer(),
            userID: userID,
            now: { date },
            currentTimeZone: { timeZone }
        )
    }

    private func makeImportedPhoto(id: UUID = UUID()) -> ImportedPhoto {
        ImportedPhoto(
            id: id,
            contentTypeIdentifier: "public.jpeg",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            byteCount: 2_048,
            originalRelativePath: "Photos/\(id.uuidString)/original.jpg",
            thumbnailRelativePath: "Photos/\(id.uuidString)/thumbnail.jpg"
        )
    }

    private func makeReadySnapshot(
        photo: ImportedPhoto,
        annotationText: String
    ) -> CaptureDraftPhotoSnapshot {
        CaptureDraftPhotoSnapshot(
            id: photo.id,
            status: .ready,
            annotationText: annotationText,
            mediaMetadata: CaptureDraftPhotoSnapshot.MediaMetadata(
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        )
    }

    private func waitForDraftRestoration(
        _ model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if !model.isRestoringDraft {
                return
            }
            await Task.yield()
        }

        XCTFail("等待 AppModel 恢复草稿超时", file: file, line: line)
    }

    private func waitUntil(
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }

        XCTFail("等待异步操作超时", file: file, line: line)
    }
}

private actor FakeDayWorkspace: DayWorkspace {
    private let shouldFailEntries: Bool
    private let committedDraftIDs: Set<UUID>
    private let externalPhotoIDs: Set<UUID>
    private var createCalls = 0
    private var allPhotoIDCalls = 0
    private var drafts: [NewEntry] = []
    private var storedEntries: [Entry] = []

    init(
        shouldFailEntries: Bool = false,
        committedDraftIDs: Set<UUID> = [],
        externalPhotoIDs: Set<UUID> = []
    ) {
        self.shouldFailEntries = shouldFailEntries
        self.committedDraftIDs = committedDraftIDs
        self.externalPhotoIDs = externalPhotoIDs
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        createCalls += 1
        drafts.append(draft)

        let entryID = UUID()
        let photos = draft.photos.enumerated().map { index, photo in
            PhotoAttachment(
                id: photo.id,
                entryID: entryID,
                sortIndex: index,
                annotationText: photo.annotationText,
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        }
        let entry = Entry(
            id: entryID,
            userID: userID,
            sourceDraftID: draft.sourceDraftID,
            dayKey: DayKey(containing: context.instant, in: context.timeZone),
            createdAt: context.instant,
            updatedAt: context.instant,
            creationTimeZoneIdentifier: context.timeZone.identifier,
            text: draft.text,
            photos: photos
        )
        storedEntries.append(entry)
        return entry
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        guard !shouldFailEntries else {
            throw FakeAppModelDependencyError.entriesRefreshFailed
        }

        return storedEntries
            .filter { $0.dayKey == day && $0.userID == userID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func photoIDs(userID: UUID) async throws -> Set<UUID> {
        Set(
            storedEntries
                .filter { $0.userID == userID }
                .flatMap(\.photos)
                .map(\.id)
        )
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool {
        committedDraftIDs.contains(id) || storedEntries.contains { entry in
            entry.userID == userID && entry.sourceDraftID == id
        }
    }

    func allPhotoIDs() async throws -> Set<UUID> {
        allPhotoIDCalls += 1
        return Set(storedEntries.flatMap(\.photos).map(\.id)).union(externalPhotoIDs)
    }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> {
        Set(
            storedEntries
                .filter { $0.userID == userID }
                .flatMap(\.voices)
                .filter { $0.originalRelativePath != nil }
                .map(\.id)
        )
    }

    func allRetainedVoiceIDs() async throws -> Set<UUID> {
        Set(
            storedEntries
                .flatMap(\.voices)
                .filter { $0.originalRelativePath != nil }
                .map(\.id)
        )
    }

    func updateVoiceTranscript(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) async throws -> VoiceAttachment {
        throw DayWorkspaceError.voiceAttachmentNotFound
    }

    func allPhotoIDsCallCount() -> Int {
        allPhotoIDCalls
    }

    func createCallCount() -> Int {
        createCalls
    }

    func createdDrafts() -> [NewEntry] {
        drafts
    }
}

private actor FakePhotoLibrary: PhotoLibrary {
    private let operationLog: FakeOperationLog?
    private var photos: [UUID: ImportedPhoto] = [:]
    private var removedPhotoIDs: Set<UUID> = []
    private var reconciliationKeepSets: [Set<UUID>] = []

    init(operationLog: FakeOperationLog? = nil) {
        self.operationLog = operationLog
    }

    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        let photo = ImportedPhoto(
            id: id,
            contentTypeIdentifier: contentTypeIdentifier ?? "public.jpeg",
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: Int64(data.count),
            originalRelativePath: "Photos/\(id.uuidString)/original.jpg",
            thumbnailRelativePath: "Photos/\(id.uuidString)/thumbnail.jpg"
        )
        photos[id] = photo
        return photo
    }

    func removePhoto(_ photo: ImportedPhoto) async throws {
        await operationLog?.append("photo.remove")
        removedPhotoIDs.insert(photo.id)
        photos[photo.id] = nil
    }

    func data(for relativePath: String) async throws -> Data {
        Data(relativePath.utf8)
    }

    func previewData(
        for relativePath: String,
        maxPixelSize: Int
    ) async throws -> Data {
        Data("\(relativePath):\(maxPixelSize)".utf8)
    }

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        reconciliationKeepSets.append(photoIDs)
        photos = photos.filter { photoIDs.contains($0.key) }
    }

    func wasRemoved(_ id: UUID) -> Bool {
        removedPhotoIDs.contains(id)
    }

    func reconciliationCallCount() -> Int {
        reconciliationKeepSets.count
    }

    func lastReconciliationKeepSet() -> Set<UUID>? {
        reconciliationKeepSets.last
    }
}

private actor FakeAudioLibrary: AudioLibrary {
    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget {
        AudioRecordingTarget(
            id: id,
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(id.uuidString).m4a"),
            relativePath: "Audio/\(id.uuidString)/original.m4a"
        )
    }

    func completeRecording(id: UUID) async throws -> ImportedAudio {
        ImportedAudio(
            id: id,
            durationMilliseconds: 1_000,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 1_024,
            relativePath: "Audio/\(id.uuidString)/original.m4a"
        )
    }

    func playbackURL(for relativePath: String) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(relativePath)
    }

    func removeAudio(id: UUID) async throws {}

    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws {}
}

@MainActor
private final class FakeVoiceRecorder: VoiceRecorder {
    var currentDurationMilliseconds = 0
    var isRecording = false
    var onRecordingInterrupted: (@MainActor @Sendable () -> Void)?

    func requestPermission() async -> Bool { false }
    func startRecording(to fileURL: URL, maximumDuration: TimeInterval) throws {}
    func pauseRecording() {}
    func resumeRecording(maximumDuration: TimeInterval) throws {}
    func stopRecording() {}
    func cancelRecording() {}
}

@MainActor
private final class FakeSpeechTranscriber: SpeechTranscriber {
    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptResult {
        throw SpeechTranscriberError.recognizerUnavailable
    }

    func cancel() {}
}

@MainActor
private final class FakeVoicePlayer: VoicePlayer {
    var onPlaybackInterrupted: (@MainActor @Sendable () -> Void)?
    var isPlaying = false
    var currentTimeMilliseconds = 0
    var durationMilliseconds = 0

    func play(fileURL: URL) throws {}
    func pause() {}
    func resume() throws {}
    func stop() {}
}

private actor FakeCaptureDraftStore: CaptureDraftStore {
    private let shouldFailLoad: Bool
    private let shouldFailSave: Bool
    private let operationLog: FakeOperationLog?
    private var snapshot: CaptureDraftSnapshot?
    private var clearCalls = 0
    private var saveCalls = 0

    init(
        snapshot: CaptureDraftSnapshot? = nil,
        shouldFailLoad: Bool = false,
        shouldFailSave: Bool = false,
        operationLog: FakeOperationLog? = nil
    ) {
        self.snapshot = snapshot
        self.shouldFailLoad = shouldFailLoad
        self.shouldFailSave = shouldFailSave
        self.operationLog = operationLog
    }

    func load() async throws -> CaptureDraftSnapshot? {
        guard !shouldFailLoad else {
            throw FakeAppModelDependencyError.draftLoadFailed
        }
        return snapshot
    }

    func save(_ snapshot: CaptureDraftSnapshot) async throws {
        saveCalls += 1
        await operationLog?.append("draft.save")
        guard !shouldFailSave else {
            throw FakeAppModelDependencyError.draftSaveFailed
        }
        self.snapshot = snapshot
    }

    func clear() async throws {
        clearCalls += 1
        snapshot = nil
    }

    func persistedSnapshot() -> CaptureDraftSnapshot? {
        snapshot
    }

    func clearCallCount() -> Int {
        clearCalls
    }

    func saveCallCount() -> Int {
        saveCalls
    }
}

private actor FakeOperationLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func allEvents() -> [String] {
        events
    }
}

private enum FakeAppModelDependencyError: Error, Sendable {
    case entriesRefreshFailed
    case draftLoadFailed
    case draftSaveFailed
}
