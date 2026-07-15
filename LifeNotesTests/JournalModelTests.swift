import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class JournalModelTests: XCTestCase {
    private let userID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private let dayA = DayKey(year: 2026, month: 7, day: 15)!
    private let dayB = DayKey(year: 2026, month: 7, day: 16)!
    private let fixedNow = Date(timeIntervalSince1970: 1_768_435_200)

    func testLoadPublishesCurrentHistoryAndMatchingFingerprint() async throws {
        let entry = makeEntry(day: dayA, idSuffix: 1, text: "今天完成了计划。")
        let fingerprint = try JournalSourceFingerprint.make(entries: [entry])
        let first = makeVersion(
            idSuffix: 11,
            number: 1,
            title: "第一版",
            fingerprint: fingerprint
        )
        let current = makeVersion(
            idSuffix: 12,
            number: 2,
            title: "编辑版",
            origin: .edited,
            fingerprint: fingerprint,
            baseVersionID: first.id
        )
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]])
        let journalWorkspace = JournalModelTestJournalWorkspace(
            journals: [dayA: JournalDay(dayKey: dayA, currentVersion: current, historyVersions: [first])]
        )
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace
        )

        await model.load(day: dayA)

        XCTAssertEqual(model.selectedDay, dayA)
        XCTAssertEqual(model.currentVersion, current)
        XCTAssertEqual(model.historyVersions, [first])
        XCTAssertEqual(model.sourceEntries, [entry])
        XCTAssertEqual(model.sourceFingerprint, fingerprint)
        XCTAssertFalse(model.hasNewSourceMaterial)
        XCTAssertTrue(model.canGenerate)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.alert)
    }

    func testEditingExistingVersionPreservesSourceLineageAndNewMaterialNotice() async throws {
        let oldEntry = makeEntry(day: dayA, idSuffix: 1, text: "旧素材")
        let newEntry = makeEntry(day: dayA, idSuffix: 2, text: "后来新增的素材")
        let oldFingerprint = try JournalSourceFingerprint.make(entries: [oldEntry])
        let current = makeVersion(
            idSuffix: 20,
            number: 1,
            title: "旧日记",
            fingerprint: oldFingerprint,
            sourceEntryCount: 1,
            generatorIdentifier: "test.generator"
        )
        let dayWorkspace = JournalModelTestDayWorkspace(
            entriesByDay: [dayA: [oldEntry, newEntry]]
        )
        let journalWorkspace = JournalModelTestJournalWorkspace(
            journals: [dayA: JournalDay(dayKey: dayA, currentVersion: current)]
        )
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)
        XCTAssertTrue(model.hasNewSourceMaterial)

        let didSave = await model.saveEdits(
            title: "手动修订",
            blocks: [JournalBlock(text: "只修改原日记，不自动吸收新素材。")]
        )
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        let appended = try XCTUnwrap(appendedDrafts.last)

        XCTAssertTrue(didSave)
        XCTAssertEqual(appended.origin, .edited)
        XCTAssertEqual(appended.baseVersionID, current.id)
        XCTAssertEqual(appended.sourceFingerprint, oldFingerprint)
        XCTAssertEqual(appended.sourceEntryCount, 1)
        XCTAssertEqual(appended.generatorIdentifier, "test.generator")
        XCTAssertEqual(model.currentVersion?.title, "手动修订")
        XCTAssertEqual(model.historyVersions.first, current)
        XCTAssertTrue(model.hasNewSourceMaterial)
    }

    func testManualJournalCanBeFirstVersionWithoutAIOrSourceEntries() async throws {
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayA: []])
        let journalWorkspace = JournalModelTestJournalWorkspace()
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace,
            generator: JournalModelTestGenerator(
                responses: [.failure(.generatorFailed)]
            )
        )
        await model.load(day: dayA)

        XCTAssertFalse(model.canGenerate)
        let didSave = await model.saveEdits(
            title: "手写的一天",
            blocks: [JournalBlock(text: "即使 AI 不可用，我也可以自己写。")]
        )
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        let appended = try XCTUnwrap(appendedDrafts.last)

        XCTAssertTrue(didSave)
        XCTAssertEqual(appended.origin, .edited)
        XCTAssertNil(appended.baseVersionID)
        XCTAssertNil(appended.generatorIdentifier)
        XCTAssertEqual(appended.sourceEntryCount, 0)
        XCTAssertEqual(
            appended.sourceFingerprint,
            try JournalSourceFingerprint.make(entries: [])
        )
        XCTAssertEqual(model.currentVersion?.versionNumber, 1)
    }

    func testGenerateThenRegenerateAppendsImmutableHistory() async throws {
        let entry = makeEntry(day: dayA, idSuffix: 1, text: "沿河散步。")
        let fingerprint = try JournalSourceFingerprint.make(entries: [entry])
        let generator = JournalModelTestGenerator(
            responses: [
                .success(
                    GeneratedJournalDraft(
                        title: "第一篇",
                        blocks: [JournalBlock(text: "第一版生成内容")],
                        sourceFingerprint: fingerprint,
                        sourceEntryCount: 1,
                        generatorIdentifier: "test.generator"
                    )
                ),
                .success(
                    GeneratedJournalDraft(
                        title: "重新生成",
                        blocks: [JournalBlock(text: "第二版生成内容")],
                        sourceFingerprint: fingerprint,
                        sourceEntryCount: 1,
                        generatorIdentifier: "test.generator"
                    )
                )
            ]
        )
        let journalWorkspace = JournalModelTestJournalWorkspace()
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]]),
            journalWorkspace: journalWorkspace,
            generator: generator
        )
        await model.load(day: dayA)

        let didGenerate = await model.generate()
        let first = try XCTUnwrap(model.currentVersion)
        let didRegenerate = await model.regenerate()
        let attempts = await journalWorkspace.appendedDrafts()
        let requests = await generator.receivedRequests()

        XCTAssertTrue(didGenerate)
        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(attempts.map(\.origin), [.generated, .generated])
        XCTAssertNil(attempts.first?.baseVersionID)
        XCTAssertEqual(attempts.last?.baseVersionID, first.id)
        XCTAssertEqual(model.currentVersion?.title, "重新生成")
        XCTAssertEqual(model.currentVersion?.versionNumber, 2)
        XCTAssertEqual(model.historyVersions, [first])
        XCTAssertEqual(requests.map(\.dayKey), [dayA, dayA])
        XCTAssertEqual(requests.map(\.style), [.natural, .natural])
        XCTAssertFalse(model.hasNewSourceMaterial)
    }

    func testPreviewAndRestoreCreateNewVersionFromHistoricalSnapshot() async throws {
        let entry = makeEntry(day: dayA, idSuffix: 1, text: "素材")
        let fingerprint = try JournalSourceFingerprint.make(entries: [entry])
        let first = makeVersion(
            idSuffix: 31,
            number: 1,
            title: "想恢复的版本",
            fingerprint: fingerprint,
            generatorIdentifier: "test.generator"
        )
        let current = makeVersion(
            idSuffix: 32,
            number: 2,
            title: "当前版本",
            origin: .edited,
            fingerprint: fingerprint,
            baseVersionID: first.id,
            generatorIdentifier: "test.generator"
        )
        let journalWorkspace = JournalModelTestJournalWorkspace(
            journals: [dayA: JournalDay(dayKey: dayA, currentVersion: current, historyVersions: [first])]
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]]),
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)

        model.preview(first)
        XCTAssertEqual(model.previewedVersion, first)
        let didRestore = await model.restorePreviewedVersion()
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        let appended = try XCTUnwrap(appendedDrafts.last)

        XCTAssertTrue(didRestore)
        XCTAssertEqual(appended.origin, .restored)
        XCTAssertEqual(appended.title, first.title)
        XCTAssertEqual(appended.blocks, first.blocks)
        XCTAssertEqual(appended.baseVersionID, first.id)
        XCTAssertEqual(appended.sourceFingerprint, first.sourceFingerprint)
        XCTAssertEqual(model.currentVersion?.origin, .restored)
        XCTAssertEqual(model.currentVersion?.versionNumber, 3)
        XCTAssertEqual(model.historyVersions, [current, first])
        XCTAssertNil(model.previewedVersion)
    }

    func testLoadGenerateAndAppendFailuresPreserveCurrentVersion() async throws {
        let entry = makeEntry(day: dayA, idSuffix: 1, text: "现有素材")
        let fingerprint = try JournalSourceFingerprint.make(entries: [entry])
        let current = makeVersion(
            idSuffix: 40,
            number: 1,
            title: "不能被失败覆盖",
            fingerprint: fingerprint
        )
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]])
        let journalWorkspace = JournalModelTestJournalWorkspace(
            journals: [dayA: JournalDay(dayKey: dayA, currentVersion: current)]
        )
        let generator = JournalModelTestGenerator(
            responses: [.failure(.generatorFailed)]
        )
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace,
            generator: generator
        )
        await model.load(day: dayA)

        await journalWorkspace.enqueueJournalResponse(
            for: dayA,
            .failure(.loadFailed)
        )
        await model.load(day: dayA)
        XCTAssertEqual(model.currentVersion, current)
        XCTAssertNotNil(model.alert)

        let didRegenerate = await model.regenerate()
        XCTAssertFalse(didRegenerate)
        XCTAssertEqual(model.currentVersion, current)
        XCTAssertNotNil(model.alert)

        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(shouldFail: true)
        )
        let didSave = await model.saveEdits(
            title: "失败的编辑",
            blocks: [JournalBlock(text: "不会覆盖当前版本")]
        )
        XCTAssertFalse(didSave)
        XCTAssertEqual(model.currentVersion, current)
        XCTAssertEqual(model.historyVersions, [])
        XCTAssertNotNil(model.alert)
    }

    func testCanGenerateRequiresUnderstandableText() async throws {
        let silentPhoto = makePhoto(idSuffix: 51, annotation: "")
        let photoOnly = makeEntry(
            day: dayA,
            idSuffix: 51,
            text: "",
            photos: [silentPhoto]
        )
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayA: [photoOnly]])
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: JournalModelTestJournalWorkspace()
        )

        await model.load(day: dayA)
        XCTAssertFalse(model.canGenerate)

        let annotated = makeEntry(
            day: dayA,
            idSuffix: 52,
            text: "",
            photos: [makePhoto(idSuffix: 52, annotation: "晚霞")]
        )
        await dayWorkspace.setEntries([annotated], for: dayA)
        await model.load(day: dayA)
        XCTAssertTrue(model.canGenerate)

        let transcribed = makeEntry(
            day: dayA,
            idSuffix: 53,
            text: "",
            voices: [makeVoice(idSuffix: 53, transcript: "风很轻")]
        )
        await dayWorkspace.setEntries([transcribed], for: dayA)
        await model.load(day: dayA)
        XCTAssertTrue(model.canGenerate)
    }

    func testGeneratedPhotoMustBeAnExactSnapshotFromSourceEntries() async throws {
        let sourcePhoto = makePhoto(idSuffix: 54, annotation: "傍晚的河")
        let sourceEntry = makeEntry(
            day: dayA,
            idSuffix: 54,
            text: "散步",
            photos: [sourcePhoto]
        )
        let fingerprint = try JournalSourceFingerprint.make(entries: [sourceEntry])
        let injectedPhoto = makePhoto(idSuffix: 55, annotation: "不属于素材")
        let generator = JournalModelTestGenerator(
            responses: [
                .success(
                    GeneratedJournalDraft(
                        title: "错误照片",
                        blocks: [JournalBlock(photo: injectedPhoto)],
                        sourceFingerprint: fingerprint,
                        sourceEntryCount: 1,
                        generatorIdentifier: "test.generator"
                    )
                )
            ]
        )
        let journalWorkspace = JournalModelTestJournalWorkspace()
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(
                entriesByDay: [dayA: [sourceEntry]]
            ),
            journalWorkspace: journalWorkspace,
            generator: generator
        )
        await model.load(day: dayA)

        let didGenerate = await model.generate()
        let appendedDrafts = await journalWorkspace.appendedDrafts()

        XCTAssertFalse(didGenerate)
        XCTAssertTrue(appendedDrafts.isEmpty)
        XCTAssertNil(model.currentVersion)
        XCTAssertNotNil(model.alert)
    }

    func testLateLoadCannotOverwriteNewerDay() async throws {
        let gate = JournalModelTestGate()
        let entryA = makeEntry(day: dayA, idSuffix: 61, text: "A")
        let entryB = makeEntry(day: dayB, idSuffix: 62, text: "B")
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayB: [entryB]])
        await dayWorkspace.enqueueResponse(
            JournalModelEntriesResponse(entries: [entryA], gate: gate),
            for: dayA
        )
        let journalWorkspace = JournalModelTestJournalWorkspace()
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace
        )

        let loadA = Task { await model.load(day: dayA) }
        await waitUntil { await gate.hasWaiter() }
        await model.load(day: dayB)
        XCTAssertEqual(model.selectedDay, dayB)
        XCTAssertEqual(model.sourceEntries, [entryB])

        await gate.open()
        await loadA.value

        XCTAssertEqual(model.selectedDay, dayB)
        XCTAssertEqual(model.sourceEntries, [entryB])
        XCTAssertNil(model.journalDay)
    }

    func testFirstALoadCannotOverwriteAAfterAToBToA() async throws {
        let gate = JournalModelTestGate()
        let staleA = makeEntry(day: dayA, idSuffix: 71, text: "过期的 A")
        let currentA = makeEntry(day: dayA, idSuffix: 72, text: "最新的 A")
        let entryB = makeEntry(day: dayB, idSuffix: 73, text: "B")
        let dayWorkspace = JournalModelTestDayWorkspace(entriesByDay: [dayB: [entryB]])
        await dayWorkspace.enqueueResponse(
            JournalModelEntriesResponse(entries: [staleA], gate: gate),
            for: dayA
        )
        await dayWorkspace.enqueueResponse(
            JournalModelEntriesResponse(entries: [currentA]),
            for: dayA
        )
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: JournalModelTestJournalWorkspace()
        )

        let firstLoadA = Task { await model.load(day: dayA) }
        await waitUntil { await gate.hasWaiter() }
        await model.load(day: dayB)
        await model.load(day: dayA)
        XCTAssertEqual(model.sourceEntries, [currentA])

        await gate.open()
        await firstLoadA.value

        XCTAssertEqual(model.selectedDay, dayA)
        XCTAssertEqual(model.sourceEntries, [currentA])
    }

    func testLateGenerationAfterAToBToADoesNotAppendOrPublish() async throws {
        let gate = JournalModelTestGate()
        let entryA = makeEntry(day: dayA, idSuffix: 81, text: "A 的素材")
        let entryB = makeEntry(day: dayB, idSuffix: 82, text: "B 的素材")
        let fingerprintA = try JournalSourceFingerprint.make(entries: [entryA])
        let generator = JournalModelTestGenerator(
            responses: [
                JournalModelGeneratorResponse(
                    result: .success(
                        GeneratedJournalDraft(
                            title: "迟到的 A",
                            blocks: [JournalBlock(text: "不应写入")],
                            sourceFingerprint: fingerprintA,
                            sourceEntryCount: 1,
                            generatorIdentifier: "test.generator"
                        )
                    ),
                    gate: gate
                )
            ]
        )
        let dayWorkspace = JournalModelTestDayWorkspace(
            entriesByDay: [dayA: [entryA], dayB: [entryB]]
        )
        let journalWorkspace = JournalModelTestJournalWorkspace()
        let model = makeModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace,
            generator: generator
        )
        await model.load(day: dayA)

        let generation = Task { await model.generate() }
        await waitUntil { await gate.hasWaiter() }
        await model.load(day: dayB)
        await model.load(day: dayA)
        await gate.open()
        let didGenerate = await generation.value

        XCTAssertFalse(didGenerate)
        XCTAssertEqual(model.selectedDay, dayA)
        XCTAssertNil(model.currentVersion)
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        XCTAssertEqual(appendedDrafts, [])
        XCTAssertFalse(model.isGenerating)
        XCTAssertNil(model.alert)
    }

    func testPersistedLateAppendDoesNotReplaceSelectedDay() async throws {
        let appendGate = JournalModelTestGate()
        let entryA = makeEntry(day: dayA, idSuffix: 91, text: "A 的素材")
        let entryB = makeEntry(day: dayB, idSuffix: 92, text: "B 的素材")
        let fingerprintA = try JournalSourceFingerprint.make(entries: [entryA])
        let generator = JournalModelTestGenerator(
            responses: [
                .success(
                    GeneratedJournalDraft(
                        title: "A 的日记",
                        blocks: [JournalBlock(text: "会持久化但不能覆盖 B")],
                        sourceFingerprint: fingerprintA,
                        sourceEntryCount: 1,
                        generatorIdentifier: "test.generator"
                    )
                )
            ]
        )
        let journalWorkspace = JournalModelTestJournalWorkspace()
        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(gate: appendGate)
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(
                entriesByDay: [dayA: [entryA], dayB: [entryB]]
            ),
            journalWorkspace: journalWorkspace,
            generator: generator
        )
        await model.load(day: dayA)

        let generation = Task { await model.generate() }
        await waitUntil { await appendGate.hasWaiter() }
        await model.load(day: dayB)
        await appendGate.open()
        let didGenerate = await generation.value

        XCTAssertTrue(didGenerate)
        XCTAssertEqual(model.selectedDay, dayB)
        XCTAssertEqual(model.sourceEntries.map(\.text), ["B 的素材"])
        XCTAssertNil(model.currentVersion)
        XCTAssertFalse(model.isGenerating)
        XCTAssertNil(model.alert)
    }

    func testSameDayLoadDoesNotClearSavingAndAppendPublishes() async throws {
        let appendGate = JournalModelTestGate()
        let entry = makeEntry(day: dayA, idSuffix: 101, text: "同日素材")
        let journalWorkspace = JournalModelTestJournalWorkspace()
        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(gate: appendGate)
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]]),
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)

        let saving = Task {
            await model.saveEdits(
                title: "同日保存",
                blocks: [JournalBlock(text: "保存期间刷新素材")]
            )
        }
        await waitUntil { await appendGate.hasWaiter() }
        XCTAssertTrue(model.isSaving)

        await model.load(day: dayA, showError: false)

        XCTAssertTrue(model.isSaving)
        XCTAssertNil(model.currentVersion)

        await appendGate.open()
        let didSave = await saving.value

        XCTAssertTrue(didSave)
        XCTAssertEqual(model.currentVersion?.title, "同日保存")
        XCTAssertFalse(model.isSaving)
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        XCTAssertEqual(appendedDrafts.count, 1)
        XCTAssertNil(model.alert)
    }

    func testLateSameDayLoadCannotOverwritePersistedAppend() async throws {
        let appendGate = JournalModelTestGate()
        let loadGate = JournalModelTestGate()
        let entry = makeEntry(day: dayA, idSuffix: 102, text: "同日素材")
        let journalWorkspace = JournalModelTestJournalWorkspace()
        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(gate: appendGate)
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]]),
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)
        await journalWorkspace.enqueueJournalResponse(
            for: dayA,
            .success(nil, gate: loadGate)
        )

        let saving = Task {
            await model.saveEdits(
                title: "不能被旧加载覆盖",
                blocks: [JournalBlock(text: "已经落库")]
            )
        }
        await waitUntil { await appendGate.hasWaiter() }
        let refresh = Task { await model.load(day: dayA, showError: false) }
        await waitUntil { await loadGate.hasWaiter() }

        await appendGate.open()
        let didSave = await saving.value
        XCTAssertTrue(didSave)
        XCTAssertEqual(model.currentVersion?.title, "不能被旧加载覆盖")

        await loadGate.open()
        await refresh.value

        XCTAssertEqual(model.currentVersion?.title, "不能被旧加载覆盖")
        XCTAssertEqual(model.currentVersion?.versionNumber, 1)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.alert)
    }

    func testSameDayLoadDuringRestoreKeepsSavingAndPreview() async throws {
        let appendGate = JournalModelTestGate()
        let entry = makeEntry(day: dayA, idSuffix: 103, text: "恢复素材")
        let fingerprint = try JournalSourceFingerprint.make(entries: [entry])
        let first = makeVersion(
            idSuffix: 104,
            number: 1,
            title: "准备恢复",
            fingerprint: fingerprint
        )
        let current = makeVersion(
            idSuffix: 105,
            number: 2,
            title: "当前版本",
            origin: .edited,
            fingerprint: fingerprint,
            baseVersionID: first.id
        )
        let journalWorkspace = JournalModelTestJournalWorkspace(
            journals: [
                dayA: JournalDay(
                    dayKey: dayA,
                    currentVersion: current,
                    historyVersions: [first]
                )
            ]
        )
        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(gate: appendGate)
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(entriesByDay: [dayA: [entry]]),
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)
        model.preview(first)

        let restoring = Task { await model.restorePreviewedVersion() }
        await waitUntil { await appendGate.hasWaiter() }
        await model.load(day: dayA, showError: false)

        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.previewedVersion, first)

        await appendGate.open()
        let didRestore = await restoring.value

        XCTAssertTrue(didRestore)
        XCTAssertEqual(model.currentVersion?.origin, .restored)
        XCTAssertEqual(model.currentVersion?.baseVersionID, first.id)
        XCTAssertNil(model.previewedVersion)
        XCTAssertFalse(model.isSaving)
    }

    func testPersistedAppendReloadsAfterAToBToA() async throws {
        let appendGate = JournalModelTestGate()
        let entryA = makeEntry(day: dayA, idSuffix: 106, text: "A 的素材")
        let entryB = makeEntry(day: dayB, idSuffix: 107, text: "B 的素材")
        let journalWorkspace = JournalModelTestJournalWorkspace()
        await journalWorkspace.enqueueAppendBehavior(
            JournalModelAppendBehavior(gate: appendGate)
        )
        let model = makeModel(
            dayWorkspace: JournalModelTestDayWorkspace(
                entriesByDay: [dayA: [entryA], dayB: [entryB]]
            ),
            journalWorkspace: journalWorkspace
        )
        await model.load(day: dayA)

        let saving = Task {
            await model.saveEdits(
                title: "已落库的 A",
                blocks: [JournalBlock(text: "切日不能制造重复版本")]
            )
        }
        await waitUntil { await appendGate.hasWaiter() }
        await model.load(day: dayB)
        await model.load(day: dayA)
        let loadCountBeforeAppend = await journalWorkspace.journalRequestCount(for: dayA)

        await appendGate.open()
        let didSave = await saving.value

        XCTAssertTrue(didSave)
        XCTAssertEqual(model.selectedDay, dayA)
        XCTAssertEqual(model.currentVersion?.title, "已落库的 A")
        XCTAssertEqual(model.currentVersion?.versionNumber, 1)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.alert)
        let loadCountAfterAppend = await journalWorkspace.journalRequestCount(for: dayA)
        XCTAssertEqual(loadCountAfterAppend, loadCountBeforeAppend + 1)
        let appendedDrafts = await journalWorkspace.appendedDrafts()
        XCTAssertEqual(appendedDrafts.count, 1)
    }

    private func makeModel(
        dayWorkspace: JournalModelTestDayWorkspace,
        journalWorkspace: JournalModelTestJournalWorkspace,
        generator: JournalModelTestGenerator = JournalModelTestGenerator()
    ) -> JournalModel {
        let fixedNow = fixedNow
        return JournalModel(
            dayWorkspace: dayWorkspace,
            journalWorkspace: journalWorkspace,
            generator: generator,
            userID: userID,
            now: { fixedNow }
        )
    }

    private func makeVersion(
        idSuffix: UInt8,
        number: Int,
        title: String,
        origin: JournalVersionOrigin = .generated,
        fingerprint: JournalSourceFingerprint,
        sourceEntryCount: Int = 1,
        baseVersionID: UUID? = nil,
        generatorIdentifier: String? = "test.generator"
    ) -> JournalVersion {
        JournalVersion(
            id: uuid(idSuffix),
            versionNumber: number,
            title: title,
            blocks: [JournalBlock(text: "\(title)的内容")],
            origin: origin,
            sourceFingerprint: fingerprint,
            sourceEntryCount: sourceEntryCount,
            baseVersionID: baseVersionID,
            generatorIdentifier: generatorIdentifier,
            createdAt: Date(timeIntervalSince1970: Double(number))
        )
    }

    private func makeEntry(
        day: DayKey,
        idSuffix: UInt8,
        text: String,
        photos: [PhotoAttachment] = [],
        voices: [VoiceAttachment] = []
    ) -> Entry {
        let id = uuid(idSuffix)
        return Entry(
            id: id,
            userID: userID,
            dayKey: day,
            createdAt: Date(timeIntervalSince1970: Double(idSuffix)),
            updatedAt: Date(timeIntervalSince1970: Double(idSuffix)),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            text: text,
            photos: photos.map {
                PhotoAttachment(
                    id: $0.id,
                    entryID: id,
                    sortIndex: $0.sortIndex,
                    annotationText: $0.annotationText,
                    contentTypeIdentifier: $0.contentTypeIdentifier,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    byteCount: $0.byteCount,
                    originalRelativePath: $0.originalRelativePath,
                    thumbnailRelativePath: $0.thumbnailRelativePath
                )
            },
            voices: voices.map {
                VoiceAttachment(
                    id: $0.id,
                    entryID: id,
                    targetPhotoID: $0.targetPhotoID,
                    sortIndex: $0.sortIndex,
                    durationMilliseconds: $0.durationMilliseconds,
                    contentTypeIdentifier: $0.contentTypeIdentifier,
                    byteCount: $0.byteCount,
                    originalRelativePath: $0.originalRelativePath,
                    transcriptText: $0.transcriptText,
                    transcriptionStatus: $0.transcriptionStatus,
                    transcriptionSource: $0.transcriptionSource,
                    sourceLocaleIdentifier: $0.sourceLocaleIdentifier,
                    isTranscriptUserEdited: $0.isTranscriptUserEdited
                )
            }
        )
    }

    private func makePhoto(idSuffix: UInt8, annotation: String) -> PhotoAttachment {
        let id = uuid(idSuffix)
        return PhotoAttachment(
            id: id,
            entryID: uuid(250),
            sortIndex: 0,
            annotationText: annotation,
            contentTypeIdentifier: "public.jpeg",
            pixelWidth: 1_200,
            pixelHeight: 800,
            byteCount: 4_096,
            originalRelativePath: "Photos/\(id.uuidString)/original.jpg",
            thumbnailRelativePath: "Photos/\(id.uuidString)/thumbnail.jpg"
        )
    }

    private func makeVoice(idSuffix: UInt8, transcript: String) -> VoiceAttachment {
        VoiceAttachment(
            id: uuid(idSuffix),
            entryID: uuid(250),
            sortIndex: 0,
            durationMilliseconds: 2_000,
            transcriptText: transcript,
            transcriptionStatus: .completed,
            transcriptionSource: .onDevice,
            sourceLocaleIdentifier: "zh-CN"
        )
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("等待异步条件超时", file: file, line: line)
    }
}

private enum JournalModelTestError: Error, Sendable {
    case unsupported
    case loadFailed
    case appendFailed
    case generatorFailed
}

private actor JournalModelTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func hasWaiter() -> Bool {
        !continuations.isEmpty
    }

    func open() {
        let waiters = continuations
        continuations.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct JournalModelEntriesResponse: Sendable {
    let result: Result<[Entry], JournalModelTestError>
    let gate: JournalModelTestGate?

    init(entries: [Entry], gate: JournalModelTestGate? = nil) {
        result = .success(entries)
        self.gate = gate
    }

    init(error: JournalModelTestError, gate: JournalModelTestGate? = nil) {
        result = .failure(error)
        self.gate = gate
    }
}

private actor JournalModelTestDayWorkspace: DayWorkspace {
    private var entriesByDay: [DayKey: [Entry]]
    private var responsesByDay: [DayKey: [JournalModelEntriesResponse]] = [:]

    init(entriesByDay: [DayKey: [Entry]] = [:]) {
        self.entriesByDay = entriesByDay
    }

    func setEntries(_ entries: [Entry], for day: DayKey) {
        entriesByDay[day] = entries
    }

    func enqueueResponse(_ response: JournalModelEntriesResponse, for day: DayKey) {
        responsesByDay[day, default: []].append(response)
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        let response: JournalModelEntriesResponse
        if var responses = responsesByDay[day], !responses.isEmpty {
            response = responses.removeFirst()
            responsesByDay[day] = responses
        } else {
            response = JournalModelEntriesResponse(entries: entriesByDay[day, default: []])
        }
        if let gate = response.gate {
            await gate.wait()
        }
        return try response.result.get()
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        throw JournalModelTestError.unsupported
    }

    func daySummaries(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) async throws -> [CalendarDaySummary] {
        []
    }

    func dayDetail(for day: DayKey, userID: UUID) async throws -> DayDetail {
        DayDetail(
            dayKey: day,
            entries: try await entries(for: day, userID: userID),
            state: DayState(dayKey: day)
        )
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
        DayState(dayKey: day, feeling: feeling, feelingUpdatedAt: updatedAt)
    }

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        DayState(dayKey: day, isImportant: isImportant, importantUpdatedAt: updatedAt)
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
        throw JournalModelTestError.unsupported
    }
}

private struct JournalModelJournalResponse: Sendable {
    let result: Result<JournalDay?, JournalModelTestError>
    let gate: JournalModelTestGate?

    init(
        result: Result<JournalDay?, JournalModelTestError>,
        gate: JournalModelTestGate? = nil
    ) {
        self.result = result
        self.gate = gate
    }

    static func success(
        _ journal: JournalDay?,
        gate: JournalModelTestGate? = nil
    ) -> JournalModelJournalResponse {
        JournalModelJournalResponse(result: .success(journal), gate: gate)
    }

    static func failure(
        _ error: JournalModelTestError,
        gate: JournalModelTestGate? = nil
    ) -> JournalModelJournalResponse {
        JournalModelJournalResponse(result: .failure(error), gate: gate)
    }
}

private struct JournalModelAppendBehavior: Sendable {
    let gate: JournalModelTestGate?
    let shouldFail: Bool

    init(gate: JournalModelTestGate? = nil, shouldFail: Bool = false) {
        self.gate = gate
        self.shouldFail = shouldFail
    }
}

private actor JournalModelTestJournalWorkspace: JournalWorkspace {
    private var journals: [DayKey: JournalDay]
    private var journalResponses: [DayKey: [JournalModelJournalResponse]] = [:]
    private var appendBehaviors: [JournalModelAppendBehavior] = []
    private var appendAttempts: [NewJournalVersion] = []
    private var journalRequests: [DayKey] = []

    init(journals: [DayKey: JournalDay] = [:]) {
        self.journals = journals
    }

    func enqueueJournalResponse(
        for day: DayKey,
        _ response: JournalModelJournalResponse
    ) {
        journalResponses[day, default: []].append(response)
    }

    func enqueueAppendBehavior(_ behavior: JournalModelAppendBehavior) {
        appendBehaviors.append(behavior)
    }

    func appendedDrafts() -> [NewJournalVersion] {
        appendAttempts
    }

    func journalRequestCount(for day: DayKey) -> Int {
        journalRequests.count { $0 == day }
    }

    func journal(for day: DayKey, userID: UUID) async throws -> JournalDay? {
        journalRequests.append(day)
        let response: JournalModelJournalResponse
        if var responses = journalResponses[day], !responses.isEmpty {
            response = responses.removeFirst()
            journalResponses[day] = responses
        } else {
            response = .success(journals[day])
        }
        if let gate = response.gate {
            await gate.wait()
        }
        return try response.result.get()
    }

    func append(
        _ draft: NewJournalVersion,
        for day: DayKey,
        userID: UUID
    ) async throws -> JournalDay {
        appendAttempts.append(draft)
        let behavior = appendBehaviors.isEmpty
            ? JournalModelAppendBehavior()
            : appendBehaviors.removeFirst()
        if let gate = behavior.gate {
            await gate.wait()
        }
        if behavior.shouldFail {
            throw JournalModelTestError.appendFailed
        }

        let existing = journals[day]
        let nextNumber = (existing?.allVersions.map(\.versionNumber).max() ?? 0) + 1
        let version = JournalVersion(
            id: draft.id,
            versionNumber: nextNumber,
            title: draft.title,
            blocks: draft.blocks,
            origin: draft.origin,
            sourceFingerprint: draft.sourceFingerprint,
            sourceEntryCount: draft.sourceEntryCount,
            baseVersionID: draft.baseVersionID,
            generatorIdentifier: draft.generatorIdentifier,
            createdAt: draft.createdAt
        )
        let updated = JournalDay(
            dayKey: day,
            currentVersion: version,
            historyVersions: existing.map {
                [$0.currentVersion] + $0.historyVersions
            } ?? []
        )
        journals[day] = updated
        return updated
    }
}

private struct JournalModelGeneratorResponse: Sendable {
    let result: Result<GeneratedJournalDraft, JournalModelTestError>
    let gate: JournalModelTestGate?

    init(
        result: Result<GeneratedJournalDraft, JournalModelTestError>,
        gate: JournalModelTestGate? = nil
    ) {
        self.result = result
        self.gate = gate
    }

    static func success(_ draft: GeneratedJournalDraft) -> JournalModelGeneratorResponse {
        JournalModelGeneratorResponse(result: .success(draft))
    }

    static func failure(_ error: JournalModelTestError) -> JournalModelGeneratorResponse {
        JournalModelGeneratorResponse(result: .failure(error))
    }
}

private actor JournalModelTestGenerator: JournalGenerator {
    nonisolated let identifier = "test.generator"

    private var responses: [JournalModelGeneratorResponse]
    private var requests: [JournalGenerationRequest] = []

    init(responses: [JournalModelGeneratorResponse] = []) {
        self.responses = responses
    }

    func receivedRequests() -> [JournalGenerationRequest] {
        requests
    }

    func generate(_ request: JournalGenerationRequest) async throws -> GeneratedJournalDraft {
        requests.append(request)
        guard !responses.isEmpty else {
            throw JournalModelTestError.generatorFailed
        }
        let response = responses.removeFirst()
        if let gate = response.gate {
            await gate.wait()
        }
        return try response.result.get()
    }
}
