import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class AppModelDayStateTests: XCTestCase {
    private let userID = UUID(uuidString: "718160E5-850B-4017-91FB-D8482A23453A")!
    private let instant = Date(timeIntervalSince1970: 1_768_435_200)
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testInitialRefreshLoadsEntriesAndDayStateForCurrentUserAndDay() async {
        let dayKey = expectedDayKey
        let entry = makeEntry(dayKey: dayKey)
        let expectedState = DayState(
            dayKey: dayKey,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: instant.addingTimeInterval(-120),
            importantUpdatedAt: instant.addingTimeInterval(-60)
        )
        let workspace = DayStateTestWorkspace(
            entries: [entry],
            state: expectedState
        )
        let model = makeModel(workspace: workspace)

        await waitForInitialLoad(model, workspace: workspace)

        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.dayState, expectedState)
        XCTAssertEqual(model.todayDate, instant)
        XCTAssertEqual(model.todayTimeZone, timeZone)
        let loadCalls = await workspace.loadCalls()
        XCTAssertEqual(
            loadCalls,
            [DayStateTestLoadCall(dayKey: dayKey, userID: userID)]
        )
    }

    func testFeelingAndImportantUpdatesPreserveTheOtherField() async {
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .calm,
            isImportant: false,
            feelingUpdatedAt: instant.addingTimeInterval(-300)
        )
        let workspace = DayStateTestWorkspace(state: initialState)
        let model = makeModel(workspace: workspace)
        await waitForInitialLoad(model, workspace: workspace)

        await model.setImportant(true)

        XCTAssertEqual(model.dayState.feeling, .calm)
        XCTAssertTrue(model.dayState.isImportant)
        XCTAssertEqual(model.dayState.feelingUpdatedAt, initialState.feelingUpdatedAt)

        await model.setFeeling(.veryHappy)

        XCTAssertEqual(model.dayState.feeling, .veryHappy)
        XCTAssertTrue(model.dayState.isImportant)
        XCTAssertEqual(model.dayState.importantUpdatedAt, instant)
        let importantCalls = await workspace.importantCalls()
        XCTAssertEqual(
            importantCalls,
            [
                DayStateTestImportantCall(
                    isImportant: true,
                    dayKey: expectedDayKey,
                    userID: userID,
                    updatedAt: instant
                )
            ]
        )
    }

    func testFeelingCanBeClearedWithoutChangingImportantFlag() async {
        let workspace = DayStateTestWorkspace(
            state: DayState(
                dayKey: expectedDayKey,
                feeling: .low,
                isImportant: true,
                importantUpdatedAt: instant.addingTimeInterval(-30)
            )
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialLoad(model, workspace: workspace)

        await model.setFeeling(nil)

        XCTAssertNil(model.dayState.feeling)
        XCTAssertTrue(model.dayState.isImportant)
        XCTAssertEqual(model.dayState.importantUpdatedAt, instant.addingTimeInterval(-30))
    }

    func testFailedUpdatesKeepPreviousStateAndShowAnAlert() async {
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: instant.addingTimeInterval(-20),
            importantUpdatedAt: instant.addingTimeInterval(-10)
        )
        let workspace = DayStateTestWorkspace(
            state: initialState,
            failsFeelingUpdate: true,
            failsImportantUpdate: true
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialLoad(model, workspace: workspace)

        await model.setFeeling(.veryLow)

        XCTAssertEqual(model.dayState, initialState)
        XCTAssertEqual(model.alert?.message, "暂时无法保存每日感受，请稍后重试。")
        XCTAssertFalse(model.isUpdatingDayState)

        model.alert = nil
        await model.setImportant(false)

        XCTAssertEqual(model.dayState, initialState)
        XCTAssertEqual(model.alert?.message, "暂时无法保存重要日标记，请稍后重试。")
        XCTAssertFalse(model.isUpdatingDayState)
    }

    func testSettingExistingValuesDoesNotRewriteTimestamps() async {
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .calm,
            isImportant: true,
            feelingUpdatedAt: instant.addingTimeInterval(-20),
            importantUpdatedAt: instant.addingTimeInterval(-10)
        )
        let workspace = DayStateTestWorkspace(state: initialState)
        let model = makeModel(workspace: workspace)
        await waitForInitialLoad(model, workspace: workspace)

        await model.setFeeling(.calm)
        await model.setImportant(true)

        let feelingCalls = await workspace.feelingCalls()
        let importantCalls = await workspace.importantCalls()

        XCTAssertEqual(model.dayState, initialState)
        XCTAssertEqual(feelingCalls, [])
        XCTAssertEqual(importantCalls, [])
    }

    func testUpdateUsesDisplayedDayAndUserAndPublishesBusyState() async {
        let gate = DayStateTestGate()
        let workspace = DayStateTestWorkspace(
            state: DayState(dayKey: expectedDayKey),
            feelingGate: gate
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialLoad(model, workspace: workspace)

        let updateTask = Task {
            await model.setFeeling(.calm)
        }
        await waitUntil { await gate.hasWaiter() }

        XCTAssertTrue(model.isUpdatingDayState)

        await gate.open()
        await updateTask.value

        XCTAssertFalse(model.isUpdatingDayState)
        let feelingCalls = await workspace.feelingCalls()
        XCTAssertEqual(
            feelingCalls,
            [
                DayStateTestFeelingCall(
                    feeling: .calm,
                    dayKey: expectedDayKey,
                    userID: userID,
                    updatedAt: instant
                )
            ]
        )
    }

    func testLateOldDayUpdatesCannotOverwriteRefreshedNewDayState() async {
        let feelingGate = DayStateTestGate()
        let importantGate = DayStateTestGate()
        let clock = DayStateTestClock(instant)
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .veryLow,
            isImportant: false,
            feelingUpdatedAt: instant.addingTimeInterval(-120),
            importantUpdatedAt: instant.addingTimeInterval(-60)
        )
        let workspace = DayStateTestWorkspace(
            state: initialState,
            feelingGate: feelingGate,
            importantGate: importantGate
        )
        let model = makeModel(workspace: workspace, now: clock.now)
        await waitForInitialLoad(model, workspace: workspace)

        let feelingTask = Task {
            await model.setFeeling(.veryHappy)
        }
        await waitUntil { await feelingGate.hasWaiter() }

        let secondDate = instant.addingTimeInterval(24 * 60 * 60)
        let secondDayKey = DayKey(containing: secondDate, in: timeZone)
        let secondDayState = DayState(
            dayKey: secondDayKey,
            feeling: .calm,
            isImportant: true,
            feelingUpdatedAt: secondDate.addingTimeInterval(-120),
            importantUpdatedAt: secondDate.addingTimeInterval(-60)
        )
        clock.set(secondDate)
        await workspace.replaceState(secondDayState)
        await model.refreshToday()

        XCTAssertEqual(model.dayState, secondDayState)
        await feelingGate.open()
        await feelingTask.value
        XCTAssertEqual(model.dayState, secondDayState)

        await workspace.replaceState(secondDayState)
        let importantTask = Task {
            await model.setImportant(false)
        }
        await waitUntil { await importantGate.hasWaiter() }

        let thirdDate = secondDate.addingTimeInterval(24 * 60 * 60)
        let thirdDayKey = DayKey(containing: thirdDate, in: timeZone)
        let thirdDayState = DayState(
            dayKey: thirdDayKey,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: thirdDate.addingTimeInterval(-120),
            importantUpdatedAt: thirdDate.addingTimeInterval(-60)
        )
        clock.set(thirdDate)
        await workspace.replaceState(thirdDayState)
        await model.refreshToday()

        XCTAssertEqual(model.dayState, thirdDayState)
        await importantGate.open()
        await importantTask.value

        XCTAssertEqual(model.dayState, thirdDayState)
        XCTAssertEqual(model.todayDate, thirdDate)
        XCTAssertFalse(model.isUpdatingDayState)

        let loadCalls = await workspace.loadCalls()
        XCTAssertEqual(
            loadCalls,
            [
                DayStateTestLoadCall(dayKey: expectedDayKey, userID: userID),
                DayStateTestLoadCall(dayKey: secondDayKey, userID: userID),
                DayStateTestLoadCall(dayKey: thirdDayKey, userID: userID)
            ]
        )
        let feelingCalls = await workspace.feelingCalls()
        XCTAssertEqual(feelingCalls.map(\.dayKey), [expectedDayKey])
        let importantCalls = await workspace.importantCalls()
        XCTAssertEqual(importantCalls.map(\.dayKey), [secondDayKey])
    }

    func testABALateFeelingUpdateCannotOverwriteNewerSameDayMutation() async {
        let oldUpdateGate = DayStateTestGate()
        let clock = DayStateTestClock(instant)
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .veryLow,
            isImportant: false,
            feelingUpdatedAt: instant.addingTimeInterval(-120)
        )
        let workspace = DayStateTestWorkspace(
            state: initialState,
            feelingGate: oldUpdateGate
        )
        let model = makeModel(workspace: workspace, now: clock.now)
        await waitForInitialLoad(model, workspace: workspace)

        let oldUpdateTask = Task {
            await model.setFeeling(.low)
        }
        await waitUntil { await oldUpdateGate.hasWaiter() }
        XCTAssertTrue(model.isUpdatingDayState)

        let secondDate = instant.addingTimeInterval(24 * 60 * 60)
        let secondDayKey = DayKey(containing: secondDate, in: timeZone)
        let secondDayState = DayState(
            dayKey: secondDayKey,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: secondDate.addingTimeInterval(-60)
        )
        clock.set(secondDate)
        await workspace.replaceState(secondDayState)
        await model.refreshToday()

        XCTAssertEqual(model.dayState, secondDayState)
        XCTAssertFalse(model.isUpdatingDayState)

        let returnedDate = instant.addingTimeInterval(60 * 60)
        let returnedDayState = DayState(
            dayKey: expectedDayKey,
            feeling: .calm,
            isImportant: false,
            feelingUpdatedAt: returnedDate.addingTimeInterval(-60)
        )
        clock.set(returnedDate)
        await workspace.replaceState(returnedDayState)
        await model.refreshToday()

        XCTAssertEqual(model.dayState, returnedDayState)
        await model.setFeeling(.veryHappy)

        let newerState = DayState(
            dayKey: expectedDayKey,
            feeling: .veryHappy,
            isImportant: false,
            feelingUpdatedAt: returnedDate
        )
        XCTAssertEqual(model.dayState, newerState)
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)

        await oldUpdateGate.open()
        await oldUpdateTask.value

        XCTAssertEqual(model.dayState, newerState)
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)

        let feelingCalls = await workspace.feelingCalls()
        XCTAssertEqual(
            feelingCalls,
            [
                DayStateTestFeelingCall(
                    feeling: .low,
                    dayKey: expectedDayKey,
                    userID: userID,
                    updatedAt: instant
                ),
                DayStateTestFeelingCall(
                    feeling: .veryHappy,
                    dayKey: expectedDayKey,
                    userID: userID,
                    updatedAt: returnedDate
                )
            ]
        )
    }

    func testLateSameDayRefreshPreservesNewFeelingAndPublishesOtherTodayData() async {
        let loadGate = DayStateTestGate()
        let clock = DayStateTestClock(instant)
        let initialState = DayState(
            dayKey: expectedDayKey,
            feeling: .low,
            isImportant: true,
            feelingUpdatedAt: instant.addingTimeInterval(-120),
            importantUpdatedAt: instant.addingTimeInterval(-60)
        )
        let workspace = DayStateTestWorkspace(state: initialState)
        let model = makeModel(workspace: workspace, now: clock.now)
        await waitForInitialLoad(model, workspace: workspace)

        let refreshDate = instant.addingTimeInterval(60 * 60)
        let refreshedEntry = makeEntry(dayKey: expectedDayKey)
        clock.set(refreshDate)
        await workspace.replaceEntries([refreshedEntry])
        await workspace.gateNextDayStateLoad(loadGate)

        let refreshTask = Task {
            await model.refreshToday()
        }
        await waitUntil { await loadGate.hasWaiter() }

        XCTAssertTrue(model.isLoadingToday)
        await model.setFeeling(.veryHappy)

        let updatedState = DayState(
            dayKey: expectedDayKey,
            feeling: .veryHappy,
            isImportant: true,
            feelingUpdatedAt: refreshDate,
            importantUpdatedAt: initialState.importantUpdatedAt
        )
        XCTAssertEqual(model.dayState, updatedState)

        await loadGate.open()
        await refreshTask.value

        XCTAssertEqual(model.dayState, updatedState)
        XCTAssertEqual(model.entries, [refreshedEntry])
        XCTAssertEqual(model.todayDate, refreshDate)
        XCTAssertEqual(model.todayTimeZone, timeZone)
        XCTAssertFalse(model.isLoadingToday)
    }

    private var expectedDayKey: DayKey {
        DayKey(containing: instant, in: timeZone)
    }

    private func makeModel(workspace: DayStateTestWorkspace) -> AppModel {
        let instant = self.instant
        return makeModel(workspace: workspace, now: { instant })
    }

    private func makeModel(
        workspace: DayStateTestWorkspace,
        now: @escaping @Sendable () -> Date
    ) -> AppModel {
        let timeZone = self.timeZone
        return AppModel(
            workspace: workspace,
            photoLibrary: DayStateTestPhotoLibrary(),
            audioLibrary: DayStateTestAudioLibrary(),
            captureDraftStore: DayStateTestDraftStore(),
            voiceRecorder: DayStateTestRecorder(),
            speechTranscriber: DayStateTestTranscriber(),
            voicePlayer: DayStateTestPlayer(),
            userID: userID,
            now: now,
            currentTimeZone: { timeZone }
        )
    }

    private func makeEntry(dayKey: DayKey) -> Entry {
        Entry(
            id: UUID(uuidString: "89068C7E-E98E-4CE2-895D-E755374CCFDB")!,
            userID: userID,
            dayKey: dayKey,
            createdAt: instant,
            updatedAt: instant,
            creationTimeZoneIdentifier: timeZone.identifier,
            text: "今天值得记住。"
        )
    }

    private func waitForInitialLoad(
        _ model: AppModel,
        workspace: DayStateTestWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil(file: file, line: line) {
            guard !model.isRestoringDraft, !model.isLoadingToday else {
                return false
            }
            return await workspace.loadCallCount() == 1
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
}

private struct DayStateTestLoadCall: Equatable, Sendable {
    let dayKey: DayKey
    let userID: UUID
}

private struct DayStateTestFeelingCall: Equatable, Sendable {
    let feeling: DailyFeeling?
    let dayKey: DayKey
    let userID: UUID
    let updatedAt: Date
}

private struct DayStateTestImportantCall: Equatable, Sendable {
    let isImportant: Bool
    let dayKey: DayKey
    let userID: UUID
    let updatedAt: Date
}

private enum DayStateTestError: Error {
    case unsupported
    case updateFailed
}

private actor DayStateTestWorkspace: DayWorkspace {
    private var storedEntries: [Entry]
    private var storedState: DayState
    private let failsFeelingUpdate: Bool
    private let failsImportantUpdate: Bool
    private var feelingGate: DayStateTestGate?
    private let importantGate: DayStateTestGate?
    private var nextDayStateLoadGate: DayStateTestGate?
    private var recordedLoadCalls: [DayStateTestLoadCall] = []
    private var recordedFeelingCalls: [DayStateTestFeelingCall] = []
    private var recordedImportantCalls: [DayStateTestImportantCall] = []

    init(
        entries: [Entry] = [],
        state: DayState,
        failsFeelingUpdate: Bool = false,
        failsImportantUpdate: Bool = false,
        feelingGate: DayStateTestGate? = nil,
        importantGate: DayStateTestGate? = nil
    ) {
        storedEntries = entries
        storedState = state
        self.failsFeelingUpdate = failsFeelingUpdate
        self.failsImportantUpdate = failsImportantUpdate
        self.feelingGate = feelingGate
        self.importantGate = importantGate
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        throw DayStateTestError.unsupported
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        storedEntries.filter { $0.dayKey == day && $0.userID == userID }
    }

    func dayState(for day: DayKey, userID: UUID) async throws -> DayState {
        recordedLoadCalls.append(DayStateTestLoadCall(dayKey: day, userID: userID))
        let snapshot = storedState
        if let loadGate = nextDayStateLoadGate {
            nextDayStateLoadGate = nil
            await loadGate.wait()
        }
        return snapshot
    }

    func setFeeling(
        _ feeling: DailyFeeling?,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        recordedFeelingCalls.append(
            DayStateTestFeelingCall(
                feeling: feeling,
                dayKey: day,
                userID: userID,
                updatedAt: updatedAt
            )
        )
        if let gate = feelingGate {
            feelingGate = nil
            await gate.wait()
        }
        guard !failsFeelingUpdate else {
            throw DayStateTestError.updateFailed
        }
        storedState = DayState(
            dayKey: day,
            feeling: feeling,
            isImportant: storedState.isImportant,
            feelingUpdatedAt: updatedAt,
            importantUpdatedAt: storedState.importantUpdatedAt
        )
        return storedState
    }

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        recordedImportantCalls.append(
            DayStateTestImportantCall(
                isImportant: isImportant,
                dayKey: day,
                userID: userID,
                updatedAt: updatedAt
            )
        )
        if let importantGate {
            await importantGate.wait()
        }
        guard !failsImportantUpdate else {
            throw DayStateTestError.updateFailed
        }
        storedState = DayState(
            dayKey: day,
            feeling: storedState.feeling,
            isImportant: isImportant,
            feelingUpdatedAt: storedState.feelingUpdatedAt,
            importantUpdatedAt: updatedAt
        )
        return storedState
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool { false }

    func photoIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allPhotoIDs() async throws -> Set<UUID> { [] }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allRetainedVoiceIDs() async throws -> Set<UUID> { [] }

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
        throw DayStateTestError.unsupported
    }

    func loadCalls() -> [DayStateTestLoadCall] { recordedLoadCalls }

    func loadCallCount() -> Int { recordedLoadCalls.count }

    func feelingCalls() -> [DayStateTestFeelingCall] { recordedFeelingCalls }

    func importantCalls() -> [DayStateTestImportantCall] { recordedImportantCalls }

    func replaceState(_ state: DayState) {
        storedState = state
    }

    func replaceEntries(_ entries: [Entry]) {
        storedEntries = entries
    }

    func gateNextDayStateLoad(_ gate: DayStateTestGate) {
        nextDayStateLoadGate = gate
    }
}

private final class DayStateTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor DayStateTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func hasWaiter() -> Bool { !continuations.isEmpty }

    func open() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor DayStateTestDraftStore: CaptureDraftStore {
    func load() async throws -> CaptureDraftSnapshot? { nil }

    func save(_ snapshot: CaptureDraftSnapshot) async throws {}

    func clear() async throws {}
}

private actor DayStateTestPhotoLibrary: PhotoLibrary {
    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        throw DayStateTestError.unsupported
    }

    func removePhoto(_ photo: ImportedPhoto) async throws {}

    func data(for relativePath: String) async throws -> Data { Data() }

    func previewData(for relativePath: String, maxPixelSize: Int) async throws -> Data {
        Data()
    }

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws {}
}

private actor DayStateTestAudioLibrary: AudioLibrary {
    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget {
        throw DayStateTestError.unsupported
    }

    func completeRecording(id: UUID) async throws -> ImportedAudio {
        throw DayStateTestError.unsupported
    }

    func playbackURL(for relativePath: String) async throws -> URL {
        throw DayStateTestError.unsupported
    }

    func removeAudio(id: UUID) async throws {}

    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws {}
}

@MainActor
private final class DayStateTestRecorder: VoiceRecorder {
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
private final class DayStateTestTranscriber: SpeechTranscriber {
    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptResult {
        throw DayStateTestError.unsupported
    }

    func cancel() {}
}

@MainActor
private final class DayStateTestPlayer: VoicePlayer {
    var isPlaying = false
    var currentTimeMilliseconds = 0
    var durationMilliseconds = 0
    var onPlaybackInterrupted: (@MainActor @Sendable () -> Void)?

    func play(fileURL: URL) throws {}

    func pause() {}

    func resume() throws {}

    func stop() {}
}
