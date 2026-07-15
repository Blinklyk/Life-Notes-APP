import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class EntryLibraryModelTests: XCTestCase {
    private let userID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE001")!
    private let dayKey = DayKey(year: 2026, month: 7, day: 15)!
    private let now = Date(timeIntervalSince1970: 1_768_435_200)

    func testSearchABADropsFirstLateAResult() async {
        let firstA = makeEntry(idSuffix: 1, text: "first alpha")
        let resultB = makeEntry(idSuffix: 2, text: "bravo")
        let latestA = makeEntry(idSuffix: 3, text: "latest alpha")
        let lateGate = EntryLibraryTestGate()
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [
                .success([firstA], gate: lateGate),
                .success([resultB]),
                .success([latestA])
            ]
        )
        let model = makeModel(workspace: workspace)

        let firstTask = Task { await model.search(matching: " alpha ") }
        await waitUntil { await lateGate.hasWaiter() }
        XCTAssertTrue(model.isSearching)

        await model.search(matching: "bravo")
        XCTAssertEqual(model.results, [resultB])
        await model.search(matching: "alpha")
        XCTAssertEqual(model.results, [latestA])

        await lateGate.open()
        await firstTask.value

        XCTAssertEqual(model.query, "alpha")
        XCTAssertEqual(model.results, [latestA])
        XCTAssertFalse(model.isSearching)
        let calls = await workspace.searchCalls()
        XCTAssertEqual(calls.map(\.query), ["alpha", "bravo", "alpha"])
        XCTAssertEqual(calls.map(\.userID), [userID, userID, userID])
    }

    func testFailedReplacementSearchClearsResultsFromPreviousQuery() async {
        let oldResult = makeEntry(idSuffix: 15, text: "旧查询结果")
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [
                .success([oldResult]),
                .failure(.failed)
            ]
        )
        let model = makeModel(workspace: workspace)

        await model.search(matching: "旧查询")
        XCTAssertEqual(model.results, [oldResult])

        await model.search(matching: "新查询")

        XCTAssertEqual(model.query, "新查询")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.alert?.message, "暂时无法搜索随心记录，请稍后重试。")
    }

    func testDatabaseDeleteFailureDoesNotReadReferencesOrDeleteMedia() async {
        let entry = makeEntry(idSuffix: 4, text: "保留")
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([entry])],
            deleteResponses: [.failure(.failed)]
        )
        let photoLibrary = EntryLibraryTestPhotoLibrary()
        let audioLibrary = EntryLibraryTestAudioLibrary()
        let model = makeModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary
        )
        await model.search(matching: "保留")
        model.select(entry)
        model.beginEditing(entry)

        let succeeded = await model.deleteEntry(entry)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.results, [entry])
        XCTAssertEqual(model.selectedEntry, entry)
        XCTAssertEqual(model.editingEntry, entry)
        XCTAssertEqual(model.alert?.message, "暂时无法删除这条随心记录，请稍后重试。")
        XCTAssertFalse(model.busyEntryIDs.contains(entry.id))
        let referenceCalls = await workspace.referenceCallCounts()
        XCTAssertEqual(referenceCalls.photo, 0)
        XCTAssertEqual(referenceCalls.audio, 0)
        let photoSweeps = await photoLibrary.sweepCalls()
        let audioSweeps = await audioLibrary.sweepCalls()
        let removedPhotos = await photoLibrary.removedPhotos()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        XCTAssertTrue(photoSweeps.isEmpty)
        XCTAssertTrue(audioSweeps.isEmpty)
        XCTAssertTrue(removedPhotos.isEmpty)
        XCTAssertTrue(removedAudioIDs.isEmpty)
    }

    func testEitherReferenceReadFailurePreventsBothMediaSweeps() async {
        let entry = makeEntry(idSuffix: 5, text: "删除")
        let workspace = EntryLibraryTestWorkspace(
            deleteResponses: [.success(entry)],
            allPhotoIDsResult: .success([UUID()]),
            allAudioIDsResult: .failure(.failed)
        )
        let photoLibrary = EntryLibraryTestPhotoLibrary()
        let audioLibrary = EntryLibraryTestAudioLibrary()
        let model = makeModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary
        )

        let succeeded = await model.deleteEntry(entry)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
        XCTAssertEqual(
            model.notice?.message,
            "记录已删除，但本地媒体暂时无法清理，之后会自动重试。"
        )
        let referenceCalls = await workspace.referenceCallCounts()
        XCTAssertEqual(referenceCalls.photo, 1)
        XCTAssertEqual(referenceCalls.audio, 1)
        let photoSweeps = await photoLibrary.sweepCalls()
        let audioSweeps = await audioLibrary.sweepCalls()
        let removedPhotos = await photoLibrary.removedPhotos()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        XCTAssertTrue(photoSweeps.isEmpty)
        XCTAssertTrue(audioSweeps.isEmpty)
        XCTAssertTrue(removedPhotos.isEmpty)
        XCTAssertTrue(removedAudioIDs.isEmpty)
    }

    func testSuccessfulDeleteKeepsJournalPhotosAndMediaFailureOnlyRaisesNotice() async {
        let journalPhotoID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE102")!
        let retainedAudioID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE103")!
        let entry = makeEntry(
            idSuffix: 6,
            text: "删除",
            photoID: journalPhotoID,
            voiceID: retainedAudioID
        )
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([entry])],
            deleteResponses: [.success(entry)],
            allPhotoIDsResult: .success([journalPhotoID]),
            allAudioIDsResult: .success([])
        )
        let photoLibrary = EntryLibraryTestPhotoLibrary()
        let audioLibrary = EntryLibraryTestAudioLibrary(shouldFailRemove: true)
        let model = makeModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary
        )
        await model.search(matching: "删除")
        model.select(entry)
        model.beginEditing(entry)

        let succeeded = await model.deleteEntry(entry)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.editingEntry)
        XCTAssertEqual(model.mutationEvent?.dayKey, dayKey)
        XCTAssertEqual(model.mutationEvent?.entryID, entry.id)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
        XCTAssertEqual(
            model.notice?.message,
            "记录已删除，但部分本地媒体暂时未能清理，之后会自动重试。"
        )

        let removedPhotos = await photoLibrary.removedPhotos()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        let photoSweeps = await photoLibrary.sweepCalls()
        let audioSweeps = await audioLibrary.sweepCalls()
        XCTAssertTrue(removedPhotos.isEmpty)
        XCTAssertEqual(removedAudioIDs, [retainedAudioID])
        XCTAssertTrue(photoSweeps.isEmpty)
        XCTAssertTrue(audioSweeps.isEmpty)
    }

    func testSuccessfulDeleteDirectlyRemovesEachReleasedPhotoAndRetainedAudio() async {
        let photoID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE105")!
        let audioID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE106")!
        let entry = makeEntry(
            idSuffix: 13,
            text: "清理",
            photoID: photoID,
            voiceID: audioID
        )
        let workspace = EntryLibraryTestWorkspace(
            deleteResponses: [.success(entry)],
            allPhotoIDsResult: .success([]),
            allAudioIDsResult: .success([])
        )
        let photoLibrary = EntryLibraryTestPhotoLibrary()
        let audioLibrary = EntryLibraryTestAudioLibrary()
        let model = makeModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary
        )

        let succeeded = await model.deleteEntry(entry)

        XCTAssertTrue(succeeded)
        XCTAssertNil(model.notice)
        let removedPhotos = await photoLibrary.removedPhotos()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        XCTAssertEqual(removedPhotos.map(\.id), [photoID])
        XCTAssertEqual(removedPhotos.first?.originalRelativePath, entry.photos.first?.originalRelativePath)
        XCTAssertEqual(removedAudioIDs, [audioID])
        let photoSweeps = await photoLibrary.sweepCalls()
        let audioSweeps = await audioLibrary.sweepCalls()
        let deleteCalls = await workspace.deleteCalls()
        XCTAssertEqual(deleteCalls.map(\.id), [entry.id])
        XCTAssertEqual(deleteCalls.map(\.expectedRevision), [entry.revision])
        XCTAssertTrue(photoSweeps.isEmpty)
        XCTAssertTrue(audioSweeps.isEmpty)
    }

    func testPreparedNewerRevisionStopsConfirmedDeleteAndRequestsRefresh() async {
        let confirmed = makeEntry(idSuffix: 16, revision: 2, text: "确认时内容")
        let current = makeEntry(idSuffix: 16, revision: 3, text: "确认后已更新")
        let workspace = EntryLibraryTestWorkspace()
        let model = makeModel(workspace: workspace)
        model.select(confirmed)

        let deleted = await model.deleteEntry(confirmed, preparedEntry: current)

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.selectedEntry, current)
        XCTAssertEqual(model.mutationEvent?.entryID, confirmed.id)
        XCTAssertEqual(model.mutationEvent?.kind, .updated)
        XCTAssertEqual(
            model.alert?.message,
            "这条随心记录已在其他位置更新，请刷新后再试。"
        )
        let deleteCalls = await workspace.deleteCalls()
        XCTAssertTrue(deleteCalls.isEmpty)
    }

    func testNotFoundDeleteWithoutSelectionStillPublishesDayRefresh() async {
        let missing = makeEntry(idSuffix: 17, text: "已在其他位置删除")
        let workspace = EntryLibraryTestWorkspace(
            deleteResponses: [.failure(.entryNotFound)]
        )
        let model = makeModel(workspace: workspace)

        let deleted = await model.deleteEntry(missing)

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.mutationEvent?.dayKey, missing.dayKey)
        XCTAssertEqual(model.mutationEvent?.entryID, missing.id)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
        XCTAssertEqual(model.alert?.message, "这条随心记录已不存在，当前内容已刷新。")
    }

    func testCompletedEditRefreshesSelectionResultsAndPublishesMutation() async {
        let original = makeEntry(idSuffix: 7, revision: 4, text: "旧内容")
        let updated = makeEntry(idSuffix: 7, revision: 5, text: "新内容")
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([original])],
            updateResponses: [.success(updated)]
        )
        let model = makeModel(workspace: workspace)
        await model.search(matching: "旧内容")
        model.select(original)
        model.beginEditing(original)

        let succeeded = await model.updateEntry(
            id: original.id,
            edit: makeEdit(from: original, text: " 新内容 ")
        )

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.selectedEntry, updated)
        XCTAssertNil(model.editingEntry)
        XCTAssertFalse(model.busyEntryIDs.contains(original.id))
        XCTAssertEqual(model.mutationEvent?.dayKey, dayKey)
        XCTAssertEqual(model.mutationEvent?.entryID, original.id)
        XCTAssertEqual(model.mutationEvent?.kind, .updated)

        let calls = await workspace.updateCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, original.id)
        XCTAssertEqual(calls.first?.userID, userID)
        XCTAssertEqual(calls.first?.edit.text, "新内容")
        XCTAssertEqual(calls.first?.updatedAt, now)
    }

    func testNoOpEditAcceptsSameRevisionAndKeepsUnicodeCrossFieldANDMatch() async {
        let photoID = UUID(uuidString: "2BA6CBBE-8E4A-43E4-9F25-55FF7FAEE104")!
        let original = makeEntry(
            idSuffix: 12,
            revision: 3,
            text: "Café",
            photoID: photoID
        )
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([original])],
            updateResponses: [.success(original)]
        )
        let model = makeModel(workspace: workspace)
        await model.search(matching: " CAFE  照片 ")
        model.select(original)
        model.beginEditing(original)

        let succeeded = await model.updateEntry(
            id: original.id,
            edit: makeEdit(from: original, text: "Café")
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.results, [original])
        XCTAssertEqual(model.selectedEntry, original)
        XCTAssertNil(model.editingEntry)
        XCTAssertEqual(model.mutationEvent?.kind, .updated)
    }

    func testBeginningEditPrefersNewerRevisionOverStaleSelection() {
        let stale = makeEntry(idSuffix: 14, revision: 2, text: "旧快照")
        let current = makeEntry(idSuffix: 14, revision: 3, text: "新快照")
        let model = makeModel(workspace: EntryLibraryTestWorkspace())

        model.select(stale)
        model.beginEditing(current)

        XCTAssertEqual(model.selectedEntry, current)
        XCTAssertEqual(model.editingEntry, current)
    }

    func testLateEditPreparationCannotReplaceNewerEditor() async {
        let first = makeEntry(idSuffix: 19, text: "第一条")
        let second = makeEntry(idSuffix: 20, text: "第二条")
        let firstGate = EntryLibraryTestGate()
        let model = makeModel(workspace: EntryLibraryTestWorkspace())

        let firstTask = Task {
            await model.prepareEditing(first) { entry in
                await firstGate.wait()
                return entry
            }
        }
        await waitUntil { await firstGate.hasWaiter() }

        await model.prepareEditing(second) { $0 }
        XCTAssertEqual(model.editingEntry, second)

        await firstGate.open()
        await firstTask.value

        XCTAssertEqual(model.selectedEntry, second)
        XCTAssertEqual(model.editingEntry, second)
    }

    func testCancelEditPreparationPreventsLatePresentation() async {
        let entry = makeEntry(idSuffix: 21, text: "即将离开页面")
        let gate = EntryLibraryTestGate()
        let model = makeModel(workspace: EntryLibraryTestWorkspace())

        let preparationTask = Task {
            await model.prepareEditing(entry) { entry in
                await gate.wait()
                return entry
            }
        }
        await waitUntil { await gate.hasWaiter() }

        model.cancelEditingPreparation()
        await gate.open()
        await preparationTask.value

        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.editingEntry)
    }

    func testEntryEditorRulesRejectClearingTheOnlyText() {
        let entry = makeEntry(idSuffix: 18, text: "唯一正文")
        let initialEdit = EntryEdit(entry: entry)
        let emptyEdit = EntryEdit(
            expectedRevision: entry.revision,
            text: "   ",
            photoAnnotations: [],
            voiceTranscripts: []
        )

        XCTAssertTrue(
            EntryEditorRules.hasUnsavedChanges(
                initialEdit: initialEdit,
                pendingEdit: emptyEdit
            )
        )
        XCTAssertFalse(
            EntryEditorRules.canSave(
                entry: entry,
                initialEdit: initialEdit,
                pendingEdit: emptyEdit
            )
        )
    }

    func testPendingTranscriptDoesNotMakeFreshEditorDirty() throws {
        let entry = makeEntry(
            idSuffix: 19,
            text: "含待处理转写",
            voiceID: UUID(),
            voiceStatus: .pending
        )
        let voice = try XCTUnwrap(entry.voices.first)
        let initialEdit = EntryEdit(entry: entry)
        let pendingEdit = EntryEdit(
            expectedRevision: entry.revision,
            text: entry.text,
            photoAnnotations: [],
            voiceTranscripts: [
                EntryEditorRules.voiceTranscriptEdit(
                    voice: voice,
                    transcript: voice.transcriptText
                )
            ]
        )

        XCTAssertEqual(pendingEdit, initialEdit)
        XCTAssertFalse(
            EntryEditorRules.hasUnsavedChanges(
                initialEdit: initialEdit,
                pendingEdit: pendingEdit
            )
        )
        XCTAssertFalse(
            EntryEditorRules.canSave(
                entry: entry,
                initialEdit: initialEdit,
                pendingEdit: pendingEdit
            )
        )
    }

    func testDeleteCompletingDuringLateEditCannotBeResurrected() async {
        let original = makeEntry(idSuffix: 8, text: "并发")
        let updated = makeEntry(idSuffix: 8, revision: 1, text: "迟到编辑")
        let editGate = EntryLibraryTestGate()
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([original])],
            updateResponses: [.success(updated, gate: editGate)],
            deleteResponses: [.success(original)]
        )
        let model = makeModel(workspace: workspace)
        await model.search(matching: "并发")
        model.select(original)
        model.beginEditing(original)

        let editTask = Task {
            await model.updateEntry(
                id: original.id,
                edit: self.makeEdit(from: original, text: "迟到编辑")
            )
        }
        await waitUntil { await editGate.hasWaiter() }
        XCTAssertTrue(model.busyEntryIDs.contains(original.id))

        let deleteSucceeded = await model.deleteEntry(original)
        XCTAssertTrue(deleteSucceeded)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.editingEntry)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)

        await editGate.open()
        let editSucceeded = await editTask.value

        XCTAssertFalse(editSucceeded)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.editingEntry)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
        XCTAssertFalse(model.busyEntryIDs.contains(original.id))
    }

    func testSearchStartedBeforeDeleteCannotRepublishDeletedEntry() async {
        let entry = makeEntry(idSuffix: 9, text: "迟到搜索")
        let searchGate = EntryLibraryTestGate()
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([entry], gate: searchGate)],
            deleteResponses: [.success(entry)]
        )
        let model = makeModel(workspace: workspace)
        model.select(entry)
        let searchTask = Task { await model.search(matching: "迟到搜索") }
        await waitUntil { await searchGate.hasWaiter() }

        let deleted = await model.deleteEntry(entry)
        XCTAssertTrue(deleted)
        XCTAssertFalse(model.isSearching)
        await searchGate.open()
        await searchTask.value

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedEntry)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
        XCTAssertFalse(model.isSearching)
    }

    func testStaleAndNotFoundErrorsUseExplicitMessages() async {
        let staleEntry = makeEntry(idSuffix: 10, revision: 2, text: "版本")
        let missingEntry = makeEntry(idSuffix: 11, text: "缺失")
        let workspace = EntryLibraryTestWorkspace(
            searchResponses: [.success([staleEntry, missingEntry])],
            updateResponses: [
                .failure(.revisionConflict(expected: 2, actual: 3))
            ],
            deleteResponses: [.failure(.entryNotFound)]
        )
        let model = makeModel(workspace: workspace)
        await model.search(matching: "内容")
        model.select(staleEntry)

        let updated = await model.updateEntry(
            id: staleEntry.id,
            edit: makeEdit(from: staleEntry, text: "新版本")
        )
        XCTAssertFalse(updated)
        XCTAssertEqual(
            model.alert?.message,
            "这条随心记录已在其他位置更新，请刷新后再试。"
        )

        model.select(missingEntry)
        let deleted = await model.deleteEntry(missingEntry)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.alert?.message, "这条随心记录已不存在，当前内容已刷新。")
        XCTAssertFalse(model.results.contains { $0.id == missingEntry.id })
        XCTAssertNil(model.selectedEntry)
        XCTAssertEqual(model.mutationEvent?.entryID, missingEntry.id)
        XCTAssertEqual(model.mutationEvent?.kind, .deleted)
    }

    private func makeModel(
        workspace: EntryLibraryTestWorkspace,
        photoLibrary: EntryLibraryTestPhotoLibrary = EntryLibraryTestPhotoLibrary(),
        audioLibrary: EntryLibraryTestAudioLibrary = EntryLibraryTestAudioLibrary()
    ) -> EntryLibraryModel {
        EntryLibraryModel(
            workspace: workspace,
            userID: userID,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary,
            now: { [now] in now }
        )
    }

    private func makeEntry(
        idSuffix: Int,
        revision: Int = 0,
        text: String,
        photoID: UUID? = nil,
        voiceID: UUID? = nil,
        voiceStatus: VoiceTranscriptionStatus = .completed
    ) -> Entry {
        let entryID = UUID(
            uuidString: String(format: "2BA6CBBE-8E4A-43E4-9F25-%012d", idSuffix)
        )!
        let photos = photoID.map {
            [
                PhotoAttachment(
                    id: $0,
                    entryID: entryID,
                    sortIndex: 0,
                    annotationText: "照片批注",
                    contentTypeIdentifier: "public.jpeg",
                    pixelWidth: 100,
                    pixelHeight: 100,
                    byteCount: 100,
                    originalRelativePath: "Photos/\($0.uuidString)/original.jpg",
                    thumbnailRelativePath: "Photos/\($0.uuidString)/thumbnail.jpg"
                )
            ]
        } ?? []
        let voices = voiceID.map {
            [
                VoiceAttachment(
                    id: $0,
                    entryID: entryID,
                    sortIndex: 0,
                    durationMilliseconds: 1_000,
                    contentTypeIdentifier: "public.mpeg-4-audio",
                    byteCount: 100,
                    originalRelativePath: VoiceAudioStoragePath.relativePath(for: $0),
                    transcriptText: "语音转写",
                    transcriptionStatus: voiceStatus,
                    transcriptionSource: .onDevice,
                    sourceLocaleIdentifier: "zh-CN"
                )
            ]
        } ?? []

        return Entry(
            id: entryID,
            userID: userID,
            dayKey: dayKey,
            createdAt: now.addingTimeInterval(TimeInterval(idSuffix)),
            updatedAt: now,
            revision: revision,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            text: text,
            photos: photos,
            voices: voices
        )
    }

    private func makeEdit(from entry: Entry, text: String) -> EntryEdit {
        EntryEdit(
            expectedRevision: entry.revision,
            text: text,
            photoAnnotations: entry.photos.map {
                EntryPhotoAnnotationEdit(
                    photoID: $0.id,
                    annotationText: $0.annotationText
                )
            },
            voiceTranscripts: entry.voices.map {
                EntryVoiceTranscriptEdit(
                    voiceID: $0.id,
                    transcriptText: $0.transcriptText,
                    transcriptionStatus: $0.transcriptionStatus,
                    transcriptionSource: $0.transcriptionSource,
                    isTranscriptUserEdited: $0.isTranscriptUserEdited,
                    sourceLocaleIdentifier: $0.sourceLocaleIdentifier
                )
            }
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let startedAt = ContinuousClock.now
        while !(await condition()) {
            if ContinuousClock.now - startedAt > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("等待异步测试条件超时")
                return
            }
            await Task.yield()
        }
    }
}

private struct EntryLibraryTestSearchCall: Equatable, Sendable {
    let query: String
    let userID: UUID
}

private struct EntryLibraryTestUpdateCall: Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let edit: EntryEdit
    let updatedAt: Date
}

private struct EntryLibraryTestDeleteCall: Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let expectedRevision: Int
    let deletedAt: Date
}

private enum EntryLibraryTestFailure: Error, Sendable {
    case failed
    case entryNotFound
    case revisionConflict(expected: Int, actual: Int)
}

private struct EntryLibraryTestResponse<Value: Sendable>: Sendable {
    let value: Value?
    let gate: EntryLibraryTestGate?
    let failure: EntryLibraryTestFailure?

    static func success(
        _ value: Value,
        gate: EntryLibraryTestGate? = nil
    ) -> Self {
        Self(value: value, gate: gate, failure: nil)
    }

    static func failure(
        _ failure: EntryLibraryTestFailure,
        gate: EntryLibraryTestGate? = nil
    ) -> Self {
        Self(value: nil, gate: gate, failure: failure)
    }
}

private actor EntryLibraryTestWorkspace: DayWorkspace {
    private var searchResponses: [EntryLibraryTestResponse<[Entry]>]
    private var updateResponses: [EntryLibraryTestResponse<Entry>]
    private var deleteResponses: [EntryLibraryTestResponse<Entry>]
    private let allPhotoIDsResult: Result<Set<UUID>, EntryLibraryTestFailure>
    private let allAudioIDsResult: Result<Set<UUID>, EntryLibraryTestFailure>
    private var recordedSearchCalls: [EntryLibraryTestSearchCall] = []
    private var recordedUpdateCalls: [EntryLibraryTestUpdateCall] = []
    private var recordedDeleteCalls: [EntryLibraryTestDeleteCall] = []
    private var photoReferenceCallCount = 0
    private var audioReferenceCallCount = 0

    init(
        searchResponses: [EntryLibraryTestResponse<[Entry]>] = [],
        updateResponses: [EntryLibraryTestResponse<Entry>] = [],
        deleteResponses: [EntryLibraryTestResponse<Entry>] = [],
        allPhotoIDsResult: Result<Set<UUID>, EntryLibraryTestFailure> = .success([]),
        allAudioIDsResult: Result<Set<UUID>, EntryLibraryTestFailure> = .success([])
    ) {
        self.searchResponses = searchResponses
        self.updateResponses = updateResponses
        self.deleteResponses = deleteResponses
        self.allPhotoIDsResult = allPhotoIDsResult
        self.allAudioIDsResult = allAudioIDsResult
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        throw EntryLibraryTestFailure.failed
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] { [] }

    func updateEntry(
        id: UUID,
        userID: UUID,
        edit: EntryEdit,
        updatedAt: Date
    ) async throws -> Entry {
        recordedUpdateCalls.append(
            EntryLibraryTestUpdateCall(
                id: id,
                userID: userID,
                edit: edit,
                updatedAt: updatedAt
            )
        )
        return try await resolve(updateResponses.removeFirst())
    }

    func deleteEntry(
        id: UUID,
        userID: UUID,
        expectedRevision: Int,
        deletedAt: Date
    ) async throws -> Entry {
        recordedDeleteCalls.append(
            EntryLibraryTestDeleteCall(
                id: id,
                userID: userID,
                expectedRevision: expectedRevision,
                deletedAt: deletedAt
            )
        )
        return try await resolve(deleteResponses.removeFirst())
    }

    func searchEntries(matching query: String, userID: UUID) async throws -> [Entry] {
        recordedSearchCalls.append(EntryLibraryTestSearchCall(query: query, userID: userID))
        return try await resolve(searchResponses.removeFirst())
    }

    func dayState(for day: DayKey, userID: UUID) async throws -> DayState {
        DayState(dayKey: day)
    }

    func setFeeling(
        _ feeling: DailyFeeling?,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        throw EntryLibraryTestFailure.failed
    }

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        throw EntryLibraryTestFailure.failed
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool { false }

    func photoIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allPhotoIDs() async throws -> Set<UUID> {
        photoReferenceCallCount += 1
        return try allPhotoIDsResult.get()
    }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allRetainedVoiceIDs() async throws -> Set<UUID> {
        audioReferenceCallCount += 1
        return try allAudioIDsResult.get()
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
        throw EntryLibraryTestFailure.failed
    }

    func searchCalls() -> [EntryLibraryTestSearchCall] { recordedSearchCalls }

    func updateCalls() -> [EntryLibraryTestUpdateCall] { recordedUpdateCalls }

    func deleteCalls() -> [EntryLibraryTestDeleteCall] { recordedDeleteCalls }

    func referenceCallCounts() -> (photo: Int, audio: Int) {
        (photoReferenceCallCount, audioReferenceCallCount)
    }

    private func resolve<Value: Sendable>(
        _ response: EntryLibraryTestResponse<Value>
    ) async throws -> Value {
        if let gate = response.gate {
            await gate.wait()
        }
        if let failure = response.failure {
            switch failure {
            case .failed:
                throw failure
            case .entryNotFound:
                throw DayWorkspaceError.entryNotFound
            case let .revisionConflict(expected, actual):
                throw DayWorkspaceError.entryRevisionConflict(
                    expected: expected,
                    actual: actual
                )
            }
        }
        guard let value = response.value else {
            throw EntryLibraryTestFailure.failed
        }
        return value
    }
}

private struct EntryLibraryTestMediaSweep: Equatable, Sendable {
    let keeping: Set<UUID>
    let olderThan: Date
}

private actor EntryLibraryTestPhotoLibrary: PhotoLibrary {
    private let shouldFailRemove: Bool
    private let shouldFailSweep: Bool
    private var recordedRemovedPhotos: [ImportedPhoto] = []
    private var recordedSweepCalls: [EntryLibraryTestMediaSweep] = []

    init(shouldFailRemove: Bool = false, shouldFailSweep: Bool = false) {
        self.shouldFailRemove = shouldFailRemove
        self.shouldFailSweep = shouldFailSweep
    }

    func importPhoto(
        id: UUID,
        fileURL: URL,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        throw EntryLibraryTestFailure.failed
    }

    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        throw EntryLibraryTestFailure.failed
    }

    func removePhoto(_ photo: ImportedPhoto) async throws {
        recordedRemovedPhotos.append(photo)
        if shouldFailRemove {
            throw EntryLibraryTestFailure.failed
        }
    }

    func data(for relativePath: String) async throws -> Data {
        throw EntryLibraryTestFailure.failed
    }

    func previewData(for relativePath: String, maxPixelSize: Int) async throws -> Data {
        throw EntryLibraryTestFailure.failed
    }

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        recordedSweepCalls.append(
            EntryLibraryTestMediaSweep(keeping: photoIDs, olderThan: olderThan)
        )
        if shouldFailSweep {
            throw EntryLibraryTestFailure.failed
        }
    }

    func sweepCalls() -> [EntryLibraryTestMediaSweep] { recordedSweepCalls }

    func removedPhotos() -> [ImportedPhoto] { recordedRemovedPhotos }
}

private actor EntryLibraryTestAudioLibrary: AudioLibrary {
    private let shouldFailRemove: Bool
    private let shouldFailSweep: Bool
    private var recordedRemovedAudioIDs: [UUID] = []
    private var recordedSweepCalls: [EntryLibraryTestMediaSweep] = []

    init(shouldFailRemove: Bool = false, shouldFailSweep: Bool = false) {
        self.shouldFailRemove = shouldFailRemove
        self.shouldFailSweep = shouldFailSweep
    }

    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget {
        throw EntryLibraryTestFailure.failed
    }

    func completeRecording(id: UUID) async throws -> ImportedAudio {
        throw EntryLibraryTestFailure.failed
    }

    func playbackURL(for relativePath: String) async throws -> URL {
        throw EntryLibraryTestFailure.failed
    }

    func removeAudio(id: UUID) async throws {
        recordedRemovedAudioIDs.append(id)
        if shouldFailRemove {
            throw EntryLibraryTestFailure.failed
        }
    }

    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        recordedSweepCalls.append(
            EntryLibraryTestMediaSweep(keeping: audioIDs, olderThan: olderThan)
        )
        if shouldFailSweep {
            throw EntryLibraryTestFailure.failed
        }
    }

    func sweepCalls() -> [EntryLibraryTestMediaSweep] { recordedSweepCalls }

    func removedAudioIDs() -> [UUID] { recordedRemovedAudioIDs }
}

private actor EntryLibraryTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func hasWaiter() -> Bool { !continuations.isEmpty }
}
