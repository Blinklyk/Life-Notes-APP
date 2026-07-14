import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class AppModelVoiceTests: XCTestCase {
    func testMicrophonePermissionDeniedLeavesDraftUnchanged() async {
        let recorder = VoiceTestRecorder(permissionGranted: false)
        let audioLibrary = VoiceTestAudioLibrary()
        let model = makeModel(
            audioLibrary: audioLibrary,
            voiceRecorder: recorder
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await model.startVoiceRecording()

        XCTAssertNil(model.draftVoice)
        XCTAssertTrue(model.canAddVoice)
        XCTAssertEqual(
            model.alert?.message,
            VoiceRecorderError.microphonePermissionDenied.localizedDescription
        )
        let prepareCallCount = await audioLibrary.prepareCallCount()
        XCTAssertEqual(prepareCallCount, 0)
        XCTAssertFalse(recorder.isRecording)
    }

    func testSuccessfulTranscriptionCanBeSavedWithOriginalAudio() async throws {
        let workspace = VoiceTestDayWorkspace()
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "傍晚的风很轻。", source: .onDevice)
            )
        )
        let model = makeModel(
            workspace: workspace,
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await recordAndFinish(model)
        await waitUntil {
            model.draftVoice?.transcriptionStatus == .completed
                && !model.isTranscribingDraftVoice
        }

        XCTAssertEqual(model.draftVoice?.transcriptText, "傍晚的风很轻。")
        XCTAssertTrue(model.canSaveDraft)

        let didSave = await model.saveDraft()
        let createdDraft = await workspace.createdDrafts().first
        let savedVoice = try XCTUnwrap(createdDraft?.voices.first)
        let removedAudioIDs = await audioLibrary.removedAudioIDs()

        XCTAssertTrue(didSave)
        XCTAssertEqual(savedVoice.transcriptText, "傍晚的风很轻。")
        XCTAssertEqual(savedVoice.transcriptionStatus, .completed)
        XCTAssertEqual(savedVoice.transcriptionSource, .onDevice)
        XCTAssertNotNil(savedVoice.originalRelativePath)
        XCTAssertEqual(removedAudioIDs, [])
    }

    func testFailedTranscriptionStillAllowsSavingOriginalAudio() async throws {
        let workspace = VoiceTestDayWorkspace()
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .failure(.recognitionFailed("本次转写失败"))
        )
        let model = makeModel(
            workspace: workspace,
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await recordAndFinish(model)
        await waitUntil {
            model.draftVoice?.transcriptionStatus == .failed
                && !model.isTranscribingDraftVoice
        }

        XCTAssertTrue(model.canSaveDraft)
        XCTAssertEqual(model.alert?.message, "本次转写失败")

        let didSave = await model.saveDraft()
        let createdDraft = await workspace.createdDrafts().first
        let savedVoice = try XCTUnwrap(createdDraft?.voices.first)
        let removedAudioIDs = await audioLibrary.removedAudioIDs()

        XCTAssertTrue(didSave)
        XCTAssertEqual(savedVoice.transcriptionStatus, .failed)
        XCTAssertTrue(savedVoice.transcriptText.isEmpty)
        XCTAssertNotNil(savedVoice.originalRelativePath)
        XCTAssertEqual(removedAudioIDs, [])
    }

    func testTranscriptOnlySaveDeletesTemporaryAudioAfterDurableDereference() async throws {
        let operationLog = VoiceTestOperationLog()
        let workspace = VoiceTestDayWorkspace(operationLog: operationLog)
        let audioLibrary = VoiceTestAudioLibrary(operationLog: operationLog)
        let draftStore = VoiceTestCaptureDraftStore(operationLog: operationLog)
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "只留下这段文字。", source: .onDevice)
            )
        )
        let model = makeModel(
            workspace: workspace,
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await recordAndFinish(model)
        await waitUntil {
            model.draftVoice?.transcriptionStatus == .completed
                && !model.isTranscribingDraftVoice
        }
        let voiceID = try XCTUnwrap(model.draftVoice?.id)
        model.setKeepOriginalAudio(false)
        await model.flushCaptureDraft()
        await operationLog.reset()

        let didSave = await model.saveDraft()
        let createdDraft = await workspace.createdDrafts().first
        let savedVoice = try XCTUnwrap(createdDraft?.voices.first)
        let events = await operationLog.allEvents()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()

        XCTAssertTrue(didSave)
        XCTAssertNil(savedVoice.originalRelativePath)
        XCTAssertEqual(savedVoice.transcriptText, "只留下这段文字。")
        XCTAssertEqual(removedAudioIDs, [voiceID])
        assertOrder(
            [
                "workspace.create",
                "draft.clear",
                "workspace.allRetainedVoiceIDs",
                "audio.remove"
            ],
            in: events
        )
    }

    func testCreateFailureKeepsTranscriptOnlyTemporaryAudioAndDraft() async throws {
        let operationLog = VoiceTestOperationLog()
        let workspace = VoiceTestDayWorkspace(
            shouldFailCreate: true,
            operationLog: operationLog
        )
        let audioLibrary = VoiceTestAudioLibrary(operationLog: operationLog)
        let draftStore = VoiceTestCaptureDraftStore(operationLog: operationLog)
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "保存失败也不能丢。", source: .onDevice)
            )
        )
        let model = makeModel(
            workspace: workspace,
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await recordAndFinish(model)
        await waitUntil {
            model.draftVoice?.transcriptionStatus == .completed
                && !model.isTranscribingDraftVoice
        }
        let voiceID = try XCTUnwrap(model.draftVoice?.id)
        model.setKeepOriginalAudio(false)
        await model.flushCaptureDraft()
        let clearCallsBeforeSave = await draftStore.clearCallCount()
        await operationLog.reset()

        let didSave = await model.saveDraft()
        let persistedSnapshot = await draftStore.persistedSnapshot()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        let clearCallCount = await draftStore.clearCallCount()
        let events = await operationLog.allEvents()

        XCTAssertFalse(didSave)
        XCTAssertEqual(model.route, .capture)
        XCTAssertEqual(model.draftVoice?.id, voiceID)
        XCTAssertEqual(persistedSnapshot?.voices.first?.id, voiceID)
        XCTAssertFalse(persistedSnapshot?.voices.first?.keepOriginalAudio ?? true)
        XCTAssertEqual(removedAudioIDs, [])
        XCTAssertEqual(clearCallCount, clearCallsBeforeSave)
        XCTAssertFalse(events.contains("audio.remove"))
    }

    func testRecordingDraftRestoresAsReadyAndPendingTranscriptionBecomesFailed() async throws {
        let voiceID = UUID(uuidString: "63B8A29A-2D0D-482D-9FCE-CF76791239F6")!
        let restoredAudio = makeAudio(id: voiceID, durationMilliseconds: 4_321)
        let draftStore = VoiceTestCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "录音中退出 App",
                photos: [],
                voices: [
                    CaptureDraftVoiceSnapshot(
                        id: voiceID,
                        captureState: .recording,
                        keepOriginalAudio: false,
                        transcriptText: "尚未完成的转写",
                        transcriptionStatus: .pending,
                        sourceLocaleIdentifier: "zh-CN"
                    )
                ]
            )
        )
        let audioLibrary = VoiceTestAudioLibrary(preloadedAudios: [restoredAudio])
        let model = makeModel(
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore
        )

        await waitForModelReady(model, audioLibrary: audioLibrary)
        let restoredVoice = try XCTUnwrap(model.draftVoice)

        XCTAssertEqual(restoredVoice.id, voiceID)
        XCTAssertEqual(restoredVoice.capturePhase, .ready(restoredAudio))
        XCTAssertFalse(restoredVoice.keepOriginalAudio)
        XCTAssertEqual(restoredVoice.transcriptionStatus, .failed)
        XCTAssertEqual(restoredVoice.transcriptText, "尚未完成的转写")
        XCTAssertEqual(restoredVoice.sourceLocaleIdentifier, "zh-CN")
        XCTAssertEqual(model.voiceElapsedMilliseconds, 4_321)
        XCTAssertFalse(model.isTranscribingDraftVoice)
        let reconciliationKeepSet = await audioLibrary.lastReconciliationKeepSet()
        XCTAssertEqual(reconciliationKeepSet, [voiceID])
    }

    func testLateTranscriptionResultDoesNotOverwriteUserEdit() async throws {
        let gate = VoiceTestGate()
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "迟到的系统转写", source: .network)
            ),
            gate: gate
        )
        let model = makeModel(
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)

        await model.startVoiceRecording()
        await model.finishVoiceRecording()
        await waitUntil { await gate.hasWaiter() }
        XCTAssertTrue(model.isTranscribingDraftVoice)

        model.updateDraftVoiceTranscript("人工编辑后的文字")
        await gate.open()
        await waitUntil { transcriber.completedCallCount == 1 }

        XCTAssertEqual(model.draftVoice?.transcriptText, "人工编辑后的文字")
        XCTAssertEqual(model.draftVoice?.transcriptionStatus, .completed)
        XCTAssertTrue(model.draftVoice?.isTranscriptUserEdited == true)
        XCTAssertFalse(model.isTranscribingDraftVoice)
    }

    func testGlobalAndPerPhotoVoicesCoexistAndPersistTargets() async throws {
        let workspace = VoiceTestDayWorkspace()
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "这一刻的声音。", source: .onDevice)
            )
        )
        let model = makeModel(
            workspace: workspace,
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)
        let firstPhoto = try addDraftPhoto(to: model)
        let secondPhoto = try addDraftPhoto(to: model)

        await recordAndFinish(model)
        await waitUntil { !model.isTranscribingDraftVoice }
        await recordAndFinish(model, targetPhotoID: firstPhoto.id)
        await waitUntil { !model.isTranscribingDraftVoice }
        await recordAndFinish(model, targetPhotoID: secondPhoto.id)
        await waitUntil { !model.isTranscribingDraftVoice }

        XCTAssertEqual(model.draftVoices.count, 3)
        XCTAssertNotNil(model.draftVoice(forPhotoID: nil))
        XCTAssertEqual(
            model.draftVoice(forPhotoID: firstPhoto.id)?.targetPhotoID,
            firstPhoto.id
        )
        XCTAssertEqual(
            model.draftVoice(forPhotoID: secondPhoto.id)?.targetPhotoID,
            secondPhoto.id
        )

        let didSave = await model.saveDraft()
        let createdDrafts = await workspace.createdDrafts()
        let createdDraft = try XCTUnwrap(createdDrafts.first)

        XCTAssertTrue(didSave)
        XCTAssertEqual(
            createdDraft.voices.map(\.targetPhotoID),
            [nil, firstPhoto.id, secondPhoto.id]
        )
    }

    func testPhotoCannotReceiveASecondVoice() async throws {
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "第一段批注。", source: .onDevice)
            )
        )
        let model = makeModel(
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)
        let photo = try addDraftPhoto(to: model)

        await recordAndFinish(model, targetPhotoID: photo.id)
        await waitUntil { !model.isTranscribingDraftVoice }
        let prepareCallsBeforeRetry = await audioLibrary.prepareCallCount()

        XCTAssertFalse(model.canAddVoice(targetPhotoID: photo.id))
        await model.startVoiceRecording(targetPhotoID: photo.id)
        let prepareCallsAfterRetry = await audioLibrary.prepareCallCount()

        XCTAssertEqual(model.draftVoices.count, 1)
        XCTAssertEqual(prepareCallsAfterRetry, prepareCallsBeforeRetry)
    }

    func testRecordingAndTranscriptionBlockStartingAnotherVoice() async throws {
        let gate = VoiceTestGate()
        let audioLibrary = VoiceTestAudioLibrary()
        let transcriber = VoiceTestSpeechTranscriber(
            result: .success(
                SpeechTranscriptResult(text: "等待中的转写。", source: .onDevice)
            ),
            gate: gate
        )
        let model = makeModel(
            audioLibrary: audioLibrary,
            speechTranscriber: transcriber
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)
        let firstPhoto = try addDraftPhoto(to: model)
        let secondPhoto = try addDraftPhoto(to: model)

        await model.startVoiceRecording(targetPhotoID: firstPhoto.id)
        let firstVoice = try XCTUnwrap(model.draftVoice(forPhotoID: firstPhoto.id))
        XCTAssertFalse(model.canAddVoice(targetPhotoID: secondPhoto.id))

        await model.startVoiceRecording(targetPhotoID: secondPhoto.id)
        XCTAssertEqual(model.draftVoices.count, 1)
        XCTAssertNil(model.draftVoice(forPhotoID: secondPhoto.id))

        await model.finishVoiceRecording(id: firstVoice.id)
        await waitUntil {
            let hasWaiter = await gate.hasWaiter()
            return hasWaiter && model.transcribingDraftVoiceID == firstVoice.id
        }
        XCTAssertFalse(model.canAddVoice(targetPhotoID: secondPhoto.id))

        await model.startVoiceRecording(targetPhotoID: secondPhoto.id)
        let prepareCallCount = await audioLibrary.prepareCallCount()
        XCTAssertEqual(model.draftVoices.count, 1)
        XCTAssertEqual(prepareCallCount, 1)

        await gate.open()
        await waitUntil { !model.isTranscribingDraftVoice }
        XCTAssertTrue(model.canAddVoice(targetPhotoID: secondPhoto.id))
    }

    func testRemovingPhotoCascadesItsVoiceAfterDraftDereference() async throws {
        let operationLog = VoiceTestOperationLog()
        let photo = makePhoto()
        let globalVoiceID = UUID(
            uuidString: "A975ED0E-5585-455D-B4DC-F3EA11DA2E82"
        )!
        let photoVoiceID = UUID(
            uuidString: "A64EE8A3-42DE-44A3-861A-CF2C042AE26A"
        )!
        let draftStore = VoiceTestCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "保留全局语音，移除逐图语音",
                photos: [makePhotoSnapshot(photo)],
                voices: [
                    makeVoiceSnapshot(id: globalVoiceID),
                    makeVoiceSnapshot(id: photoVoiceID, targetPhotoID: photo.id)
                ]
            ),
            operationLog: operationLog
        )
        let photoLibrary = VoiceTestPhotoLibrary(operationLog: operationLog)
        let audioLibrary = VoiceTestAudioLibrary(
            preloadedAudios: [
                makeAudio(id: globalVoiceID),
                makeAudio(id: photoVoiceID)
            ],
            operationLog: operationLog
        )
        let model = makeModel(
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore
        )
        await waitForModelReady(model, audioLibrary: audioLibrary)
        await model.flushCaptureDraft()
        await operationLog.reset()

        model.removeDraftPhoto(id: photo.id)
        await waitUntil {
            let removedAudioIDs = await audioLibrary.removedAudioIDs()
            let wasPhotoRemoved = await photoLibrary.wasRemoved(photo.id)
            return removedAudioIDs.contains(photoVoiceID)
                && wasPhotoRemoved
        }

        let persistedSnapshot = await draftStore.persistedSnapshot()
        let events = await operationLog.allEvents()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()

        XCTAssertTrue(model.draftPhotos.isEmpty)
        XCTAssertEqual(model.draftVoices.map(\.id), [globalVoiceID])
        XCTAssertEqual(persistedSnapshot?.photos, [])
        XCTAssertEqual(persistedSnapshot?.voices.map(\.id), [globalVoiceID])
        XCTAssertEqual(removedAudioIDs, [photoVoiceID])
        assertOrder(["draft.save", "audio.remove"], in: events)
    }

    func testRestoresMultipleTargetedVoicesAndReconcilesEveryAudioID() async throws {
        let firstPhoto = makePhoto(
            id: UUID(uuidString: "05C0B11E-15B4-42C7-BE74-62F277962D96")!
        )
        let secondPhoto = makePhoto(
            id: UUID(uuidString: "ACD6F3C5-AC7C-4F24-A9A4-64A0A898AC3D")!
        )
        let globalVoiceID = UUID(
            uuidString: "8469BB3A-C803-4AF8-AE7B-9EB23B7AE82C"
        )!
        let firstPhotoVoiceID = UUID(
            uuidString: "298D4385-C0C5-442B-8B2B-DFCB80982BC7"
        )!
        let secondPhotoVoiceID = UUID(
            uuidString: "A9E6FA05-8088-4ED5-A697-C9343AE54B0F"
        )!
        let draftStore = VoiceTestCaptureDraftStore(
            snapshot: CaptureDraftSnapshot(
                text: "三段声音",
                photos: [
                    makePhotoSnapshot(firstPhoto),
                    makePhotoSnapshot(secondPhoto)
                ],
                voices: [
                    makeVoiceSnapshot(
                        id: globalVoiceID,
                        transcriptText: "全局",
                        sourceLocaleIdentifier: "zh-CN"
                    ),
                    makeVoiceSnapshot(
                        id: firstPhotoVoiceID,
                        targetPhotoID: firstPhoto.id,
                        transcriptText: "第一张",
                        sourceLocaleIdentifier: "en-US"
                    ),
                    makeVoiceSnapshot(
                        id: secondPhotoVoiceID,
                        targetPhotoID: secondPhoto.id,
                        transcriptText: "第二张",
                        transcriptionStatus: .pending,
                        sourceLocaleIdentifier: "ja-JP"
                    )
                ]
            )
        )
        let audioLibrary = VoiceTestAudioLibrary(
            preloadedAudios: [
                makeAudio(id: globalVoiceID),
                makeAudio(id: firstPhotoVoiceID),
                makeAudio(id: secondPhotoVoiceID)
            ]
        )
        let model = makeModel(
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore
        )

        await waitForModelReady(model, audioLibrary: audioLibrary)
        let reconciliationKeepSet = await audioLibrary.lastReconciliationKeepSet()

        XCTAssertEqual(
            model.draftVoices.map(\.id),
            [globalVoiceID, firstPhotoVoiceID, secondPhotoVoiceID]
        )
        XCTAssertEqual(model.draftVoice(forPhotoID: nil)?.transcriptText, "全局")
        XCTAssertEqual(
            model.draftVoice(forPhotoID: firstPhoto.id)?.sourceLocaleIdentifier,
            "en-US"
        )
        XCTAssertEqual(
            model.draftVoice(forPhotoID: secondPhoto.id)?.transcriptionStatus,
            .failed
        )
        XCTAssertEqual(
            reconciliationKeepSet,
            [globalVoiceID, firstPhotoVoiceID, secondPhotoVoiceID]
        )
    }

    func testDuplicateGlobalVoicesPauseDraftWithoutRewritingOrCleanup() async {
        let firstVoiceID = UUID()
        let secondVoiceID = UUID()
        let snapshot = CaptureDraftSnapshot(
            text: "包含两段全局语音的异常草稿",
            photos: [],
            voices: [
                makeVoiceSnapshot(id: firstVoiceID),
                makeVoiceSnapshot(id: secondVoiceID)
            ]
        )
        let draftStore = VoiceTestCaptureDraftStore(snapshot: snapshot)
        let audioLibrary = VoiceTestAudioLibrary(
            preloadedAudios: [
                makeAudio(id: firstVoiceID),
                makeAudio(id: secondVoiceID)
            ]
        )
        let model = makeModel(
            audioLibrary: audioLibrary,
            captureDraftStore: draftStore
        )

        await waitUntil { !model.isRestoringDraft }

        let reconciliationCallCount = await audioLibrary.reconciliationCallCount()
        let removedAudioIDs = await audioLibrary.removedAudioIDs()
        let persistedSnapshot = await draftStore.persistedSnapshot()

        XCTAssertFalse(model.isCaptureDraftAvailable)
        XCTAssertTrue(model.draftVoices.isEmpty)
        XCTAssertEqual(reconciliationCallCount, 0)
        XCTAssertEqual(removedAudioIDs, [])
        XCTAssertEqual(persistedSnapshot, snapshot)
        XCTAssertEqual(
            model.alert?.message,
            "上次草稿包含无法安全恢复的语音批注。为避免丢失内容，当前记录已暂停，请保留草稿并稍后处理。"
        )
    }

    private func makeModel(
        workspace: VoiceTestDayWorkspace = VoiceTestDayWorkspace(),
        photoLibrary: VoiceTestPhotoLibrary = VoiceTestPhotoLibrary(),
        audioLibrary: VoiceTestAudioLibrary = VoiceTestAudioLibrary(),
        captureDraftStore: VoiceTestCaptureDraftStore = VoiceTestCaptureDraftStore(),
        voiceRecorder: VoiceTestRecorder? = nil,
        speechTranscriber: VoiceTestSpeechTranscriber? = nil
    ) -> AppModel {
        AppModel(
            workspace: workspace,
            photoLibrary: photoLibrary,
            audioLibrary: audioLibrary,
            captureDraftStore: captureDraftStore,
            voiceRecorder: voiceRecorder ?? VoiceTestRecorder(permissionGranted: true),
            speechTranscriber: speechTranscriber ?? VoiceTestSpeechTranscriber(
                result: .failure(.recognizerUnavailable)
            ),
            voicePlayer: VoiceTestPlayer(),
            userID: UUID(uuidString: "AC0656E3-76A7-4C95-9B90-493BBF1FCFA1")!,
            now: { Date(timeIntervalSince1970: 1_768_435_200) },
            currentTimeZone: { TimeZone(identifier: "Asia/Shanghai")! }
        )
    }

    @discardableResult
    private func recordAndFinish(
        _ model: AppModel,
        targetPhotoID: UUID? = nil
    ) async -> UUID? {
        await model.startVoiceRecording(targetPhotoID: targetPhotoID)
        guard let voice = model.draftVoice(forPhotoID: targetPhotoID),
              case .recording = voice.capturePhase else {
            XCTFail("获得权限后应开始录音")
            return nil
        }
        await model.finishVoiceRecording(id: voice.id)
        return voice.id
    }

    private func waitForModelReady(
        _ model: AppModel,
        audioLibrary: VoiceTestAudioLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil(file: file, line: line) {
            let reconciliationCallCount = await audioLibrary.reconciliationCallCount()
            return !model.isRestoringDraft && reconciliationCallCount >= 1
        }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("等待异步状态超时", file: file, line: line)
    }

    private func assertOrder(
        _ expectedEvents: [String],
        in events: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousIndex = -1
        for event in expectedEvents {
            guard let index = events.firstIndex(of: event) else {
                XCTFail("缺少事件：\(event)，实际事件：\(events)", file: file, line: line)
                return
            }
            XCTAssertGreaterThan(index, previousIndex, file: file, line: line)
            previousIndex = index
        }
    }

    private func makeAudio(
        id: UUID,
        durationMilliseconds: Int = 1_800
    ) -> ImportedAudio {
        ImportedAudio(
            id: id,
            durationMilliseconds: durationMilliseconds,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 2_048,
            relativePath: "Audio/\(id.uuidString)/original.m4a"
        )
    }

    private func addDraftPhoto(to model: AppModel) throws -> ImportedPhoto {
        let id = try XCTUnwrap(model.beginPhotoImport())
        let photo = makePhoto(id: id)
        model.completePhotoImport(id: id, photo: photo)
        return photo
    }

    private func makePhoto(id: UUID = UUID()) -> ImportedPhoto {
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

    private func makePhotoSnapshot(
        _ photo: ImportedPhoto
    ) -> CaptureDraftPhotoSnapshot {
        CaptureDraftPhotoSnapshot(
            id: photo.id,
            status: .ready,
            annotationText: "逐图批注",
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

    private func makeVoiceSnapshot(
        id: UUID,
        targetPhotoID: UUID? = nil,
        transcriptText: String = "声音批注",
        transcriptionStatus: VoiceTranscriptionStatus = .completed,
        transcriptionSource: VoiceTranscriptionSource? = nil,
        sourceLocaleIdentifier: String = "zh-CN"
    ) -> CaptureDraftVoiceSnapshot {
        CaptureDraftVoiceSnapshot(
            id: id,
            targetPhotoID: targetPhotoID,
            captureState: .ready,
            keepOriginalAudio: true,
            transcriptText: transcriptText,
            transcriptionStatus: transcriptionStatus,
            transcriptionSource: transcriptionSource,
            sourceLocaleIdentifier: sourceLocaleIdentifier
        )
    }
}

private actor VoiceTestDayWorkspace: DayWorkspace {
    private let shouldFailCreate: Bool
    private let operationLog: VoiceTestOperationLog?
    private var drafts: [NewEntry] = []
    private var storedEntries: [Entry] = []

    init(
        shouldFailCreate: Bool = false,
        operationLog: VoiceTestOperationLog? = nil
    ) {
        self.shouldFailCreate = shouldFailCreate
        self.operationLog = operationLog
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        await operationLog?.append("workspace.create")
        drafts.append(draft)
        guard !shouldFailCreate else {
            throw VoiceTestError.createFailed
        }

        let entryID = UUID()
        let voices = draft.voices.enumerated().map { index, voice in
            VoiceAttachment(
                id: voice.id,
                entryID: entryID,
                targetPhotoID: voice.targetPhotoID,
                sortIndex: index,
                durationMilliseconds: voice.durationMilliseconds,
                contentTypeIdentifier: voice.contentTypeIdentifier,
                byteCount: voice.byteCount,
                originalRelativePath: voice.originalRelativePath,
                transcriptText: voice.transcriptText,
                transcriptionStatus: voice.transcriptionStatus,
                transcriptionSource: voice.transcriptionSource,
                sourceLocaleIdentifier: voice.sourceLocaleIdentifier,
                isTranscriptUserEdited: voice.isTranscriptUserEdited
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
            voices: voices
        )
        storedEntries.append(entry)
        return entry
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        storedEntries
            .filter { $0.dayKey == day && $0.userID == userID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool {
        storedEntries.contains { $0.userID == userID && $0.sourceDraftID == id }
    }

    func photoIDs(userID: UUID) async throws -> Set<UUID> { [] }
    func allPhotoIDs() async throws -> Set<UUID> { [] }

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
        await operationLog?.append("workspace.allRetainedVoiceIDs")
        return Set(
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

    func createdDrafts() -> [NewEntry] { drafts }
}

private actor VoiceTestAudioLibrary: AudioLibrary {
    private let operationLog: VoiceTestOperationLog?
    private var audios: [UUID: ImportedAudio]
    private var prepareCalls = 0
    private var reconciliationKeepSets: [Set<UUID>] = []
    private var removedIDs: Set<UUID> = []

    init(
        preloadedAudios: [ImportedAudio] = [],
        operationLog: VoiceTestOperationLog? = nil
    ) {
        self.operationLog = operationLog
        audios = Dictionary(uniqueKeysWithValues: preloadedAudios.map { ($0.id, $0) })
    }

    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget {
        prepareCalls += 1
        let relativePath = "Audio/\(id.uuidString)/original.m4a"
        audios[id] = ImportedAudio(
            id: id,
            durationMilliseconds: 1_800,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 2_048,
            relativePath: relativePath
        )
        return AudioRecordingTarget(
            id: id,
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(id.uuidString).m4a"),
            relativePath: relativePath
        )
    }

    func completeRecording(id: UUID) async throws -> ImportedAudio {
        guard let audio = audios[id] else {
            throw AudioLibraryError.audioMissing(id)
        }
        return audio
    }

    func playbackURL(for relativePath: String) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(relativePath)
    }

    func removeAudio(id: UUID) async throws {
        await operationLog?.append("audio.remove")
        removedIDs.insert(id)
        audios[id] = nil
    }

    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        reconciliationKeepSets.append(audioIDs)
    }

    func prepareCallCount() -> Int { prepareCalls }
    func reconciliationCallCount() -> Int { reconciliationKeepSets.count }
    func lastReconciliationKeepSet() -> Set<UUID>? { reconciliationKeepSets.last }
    func removedAudioIDs() -> Set<UUID> { removedIDs }
}

@MainActor
private final class VoiceTestRecorder: VoiceRecorder {
    private let permissionGranted: Bool
    var currentDurationMilliseconds: Int
    var isRecording = false
    var onRecordingInterrupted: (@MainActor @Sendable () -> Void)?

    init(
        permissionGranted: Bool,
        currentDurationMilliseconds: Int = 1_800
    ) {
        self.permissionGranted = permissionGranted
        self.currentDurationMilliseconds = currentDurationMilliseconds
    }

    func requestPermission() async -> Bool { permissionGranted }

    func startRecording(to fileURL: URL, maximumDuration: TimeInterval) throws {
        isRecording = true
    }

    func pauseRecording() { isRecording = false }

    func resumeRecording(maximumDuration: TimeInterval) throws {
        isRecording = true
    }

    func stopRecording() { isRecording = false }
    func cancelRecording() { isRecording = false }
}

@MainActor
private final class VoiceTestSpeechTranscriber: SpeechTranscriber {
    private let result: Result<SpeechTranscriptResult, SpeechTranscriberError>
    private let gate: VoiceTestGate?
    private(set) var callCount = 0
    private(set) var completedCallCount = 0
    private(set) var cancelCallCount = 0

    init(
        result: Result<SpeechTranscriptResult, SpeechTranscriberError>,
        gate: VoiceTestGate? = nil
    ) {
        self.result = result
        self.gate = gate
    }

    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptResult {
        callCount += 1
        if let gate {
            await gate.wait()
        }
        completedCallCount += 1
        return try result.get()
    }

    func cancel() { cancelCallCount += 1 }
}

@MainActor
private final class VoiceTestPlayer: VoicePlayer {
    var onPlaybackInterrupted: (@MainActor @Sendable () -> Void)?
    var isPlaying = false
    var currentTimeMilliseconds = 0
    var durationMilliseconds = 0

    func play(fileURL: URL) throws { isPlaying = true }
    func pause() { isPlaying = false }
    func resume() throws { isPlaying = true }
    func stop() { isPlaying = false }
}

private actor VoiceTestCaptureDraftStore: CaptureDraftStore {
    private let operationLog: VoiceTestOperationLog?
    private var snapshot: CaptureDraftSnapshot?
    private var clearCalls = 0

    init(
        snapshot: CaptureDraftSnapshot? = nil,
        operationLog: VoiceTestOperationLog? = nil
    ) {
        self.snapshot = snapshot
        self.operationLog = operationLog
    }

    func load() async throws -> CaptureDraftSnapshot? { snapshot }

    func save(_ snapshot: CaptureDraftSnapshot) async throws {
        await operationLog?.append("draft.save")
        self.snapshot = snapshot
    }

    func clear() async throws {
        clearCalls += 1
        await operationLog?.append("draft.clear")
        snapshot = nil
    }

    func persistedSnapshot() -> CaptureDraftSnapshot? { snapshot }
    func clearCallCount() -> Int { clearCalls }
}

private actor VoiceTestPhotoLibrary: PhotoLibrary {
    private let operationLog: VoiceTestOperationLog?
    private var removedPhotoIDs: Set<UUID> = []

    init(operationLog: VoiceTestOperationLog? = nil) {
        self.operationLog = operationLog
    }

    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        throw PhotoLibraryError.invalidImage
    }

    func removePhoto(_ photo: ImportedPhoto) async throws {
        await operationLog?.append("photo.remove")
        removedPhotoIDs.insert(photo.id)
    }
    func data(for relativePath: String) async throws -> Data { Data() }

    func previewData(
        for relativePath: String,
        maxPixelSize: Int
    ) async throws -> Data {
        Data()
    }

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws {}

    func wasRemoved(_ id: UUID) -> Bool {
        removedPhotoIDs.contains(id)
    }
}

private actor VoiceTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func hasWaiter() -> Bool { !waiters.isEmpty }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private actor VoiceTestOperationLog {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    func allEvents() -> [String] { events }
    func reset() { events.removeAll() }
}

private enum VoiceTestError: Error, Sendable {
    case createFailed
}
