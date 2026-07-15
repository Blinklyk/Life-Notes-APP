import Foundation
import SwiftData
import XCTest
@testable import LifeNotes

final class JournalPersistenceTests: XCTestCase {
    private let userID = UUID(uuidString: "64DCE843-443F-44FD-9586-475F769C7F40")!
    private let otherUserID = UUID(uuidString: "99267C10-3E35-42D0-9807-A47469052983")!
    private let day = DayKey(year: 2026, month: 7, day: 15)!

    func testFirstAppendCreatesVersionOneAndRoundTripsPhotoSnapshotMetadata() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        let sourceEntry = try await createEntryWithPhotos(
            ids: [uuid(121)],
            userID: userID,
            container: container
        )
        let photo = try XCTUnwrap(sourceEntry.photos.first)
        let sourceFingerprint = try JournalSourceFingerprint.make(entries: [sourceEntry])
        let createdAt = Date(timeIntervalSince1970: 1_768_435_200)
        let draft = NewJournalVersion(
            title: "河边的一天",
            blocks: [
                JournalBlock(id: uuid(1), text: "傍晚去河边散步。"),
                JournalBlock(id: uuid(2), photo: photo, caption: "日记里的新说明"),
            ],
            origin: .generated,
            sourceFingerprint: sourceFingerprint,
            sourceEntryCount: 1,
            generatorIdentifier: "local.rule-based.v1",
            createdAt: createdAt
        )

        let saved = try await workspace.append(draft, for: day, userID: userID)
        let reloadedValue = try await workspace.journal(for: day, userID: userID)
        let reloaded = try XCTUnwrap(reloadedValue)

        XCTAssertEqual(saved, reloaded)
        XCTAssertEqual(reloaded.currentVersion.versionNumber, 1)
        XCTAssertEqual(reloaded.currentVersion.title, "河边的一天")
        XCTAssertEqual(reloaded.currentVersion.blocks, draft.blocks)
        XCTAssertEqual(reloaded.currentVersion.blocks.last?.photo, photo)
        XCTAssertEqual(reloaded.currentVersion.blocks.last?.caption, "日记里的新说明")
        XCTAssertEqual(reloaded.currentVersion.sourceFingerprint, sourceFingerprint)
        XCTAssertEqual(reloaded.currentVersion.sourceEntryCount, 1)
        XCTAssertEqual(reloaded.currentVersion.generatorIdentifier, "local.rule-based.v1")
        XCTAssertEqual(reloaded.currentVersion.createdAt, createdAt)
        XCTAssertTrue(reloaded.historyVersions.isEmpty)
    }

    func testGeneratedEditedAndRestoredVersionsAppendWithoutMutatingHistory() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        let firstID = uuid(10)
        let secondID = uuid(11)
        let thirdID = uuid(12)
        let sourceEntry = try await createEntryWithPhotos(
            ids: [],
            userID: userID,
            container: container
        )
        let sourceFingerprint = try JournalSourceFingerprint.make(entries: [sourceEntry])
        let first = makeDraft(
            id: firstID,
            title: "第一版",
            text: "生成内容",
            origin: .generated,
            fingerprint: sourceFingerprint,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = makeDraft(
            id: secondID,
            title: "第二版",
            text: "编辑内容",
            origin: .edited,
            fingerprint: sourceFingerprint,
            baseVersionID: firstID,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let third = makeDraft(
            id: thirdID,
            title: "恢复第一版",
            text: "生成内容",
            origin: .restored,
            fingerprint: sourceFingerprint,
            baseVersionID: firstID,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        _ = try await workspace.append(first, for: day, userID: userID)
        _ = try await workspace.append(second, for: day, userID: userID)
        let result = try await workspace.append(third, for: day, userID: userID)

        XCTAssertEqual(result.currentVersion.id, thirdID)
        XCTAssertEqual(result.currentVersion.versionNumber, 3)
        XCTAssertEqual(result.currentVersion.origin, .restored)
        XCTAssertEqual(result.currentVersion.baseVersionID, firstID)
        XCTAssertEqual(result.historyVersions.map(\.id), [secondID, firstID])
        XCTAssertEqual(result.historyVersions.map(\.versionNumber), [2, 1])
        XCTAssertEqual(result.historyVersions.map(\.title), ["第二版", "第一版"])
        XCTAssertEqual(result.historyVersions.last?.blocks.first?.text, "生成内容")

        let idempotentRetry = try await workspace.append(
            third,
            for: day,
            userID: userID
        )
        XCTAssertEqual(idempotentRetry, result)
    }

    func testSameVersionIDWithDifferentContentIsRejected() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        let id = uuid(20)
        let original = makeDraft(id: id, title: "原版", text: "正文")
        let conflicting = makeDraft(id: id, title: "冲突", text: "另一段正文")

        _ = try await workspace.append(original, for: day, userID: userID)
        do {
            _ = try await workspace.append(conflicting, for: day, userID: userID)
            XCTFail("相同版本 ID 不应覆盖已有不可变版本")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .conflictingVersionID(id))
        }
    }

    func testUnknownBaseVersionIsRejectedWithoutPartialSave() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        let missingID = uuid(30)
        let draft = makeDraft(
            id: uuid(31),
            title: "错误恢复",
            text: "内容",
            origin: .restored,
            baseVersionID: missingID
        )

        do {
            _ = try await workspace.append(draft, for: day, userID: userID)
            XCTFail("首版不应引用不存在的基础版本")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .missingBaseVersion(missingID))
        }
        let journal = try await workspace.journal(for: day, userID: userID)
        XCTAssertNil(journal)
    }

    func testJournalsRemainIsolatedByUserAndDay() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        let nextDay = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 16))

        _ = try await workspace.append(
            makeDraft(id: uuid(40), title: "我的今天", text: "A"),
            for: day,
            userID: userID
        )
        _ = try await workspace.append(
            makeDraft(id: uuid(41), title: "另一位用户", text: "B"),
            for: day,
            userID: otherUserID
        )
        _ = try await workspace.append(
            makeDraft(id: uuid(42), title: "我的明天", text: "C"),
            for: nextDay,
            userID: userID
        )

        let myToday = try await workspace.journal(for: day, userID: userID)
        let othersToday = try await workspace.journal(for: day, userID: otherUserID)
        let myNextDay = try await workspace.journal(for: nextDay, userID: userID)
        let othersNextDay = try await workspace.journal(
            for: nextDay,
            userID: otherUserID
        )
        XCTAssertEqual(myToday?.currentVersion.title, "我的今天")
        XCTAssertEqual(othersToday?.currentVersion.title, "另一位用户")
        XCTAssertEqual(myNextDay?.currentVersion.title, "我的明天")
        XCTAssertNil(othersNextDay)
    }

    func testHistoryPersistsAcrossDiskStoreReopen() async throws {
        let directory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("journal.store")
        let firstID = uuid(50)
        let secondID = uuid(51)

        try await writePersistentHistory(
            storeURL: storeURL,
            firstID: firstID,
            secondID: secondID
        )

        let reopenedContainer = try ModelContainerFactory.make(
            configurationName: "JournalRestart",
            storeURL: storeURL
        )
        let reopened = SwiftDataJournalWorkspace(modelContainer: reopenedContainer)
        let reloaded = try await reopened.journal(for: day, userID: userID)
        let journal = try XCTUnwrap(reloaded)

        XCTAssertEqual(journal.currentVersion.id, secondID)
        XCTAssertEqual(journal.currentVersion.versionNumber, 2)
        XCTAssertEqual(journal.historyVersions.map(\.id), [firstID])
    }

    func testCurrentAndHistoricalJournalPhotoSnapshotsRemainInMediaRetentionSets() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        let dayWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let firstVersionID = uuid(52)
        let sourceEntry = try await createEntryWithPhotos(
            ids: [uuid(53), uuid(54)],
            userID: userID,
            container: container
        )
        let otherSourceEntry = try await createEntryWithPhotos(
            ids: [uuid(55)],
            userID: otherUserID,
            container: container
        )
        let historicalPhoto = try XCTUnwrap(sourceEntry.photos.first)
        let currentPhoto = try XCTUnwrap(sourceEntry.photos.last)
        let otherPhoto = try XCTUnwrap(otherSourceEntry.photos.first)

        _ = try await journalWorkspace.append(
            NewJournalVersion(
                id: firstVersionID,
                title: "我的第一版照片日记",
                blocks: [JournalBlock(photo: historicalPhoto)],
                origin: .edited,
                sourceFingerprint: fingerprint("r"),
                sourceEntryCount: 0,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            for: day,
            userID: userID
        )
        _ = try await journalWorkspace.append(
            NewJournalVersion(
                id: uuid(56),
                title: "我的第二版照片日记",
                blocks: [JournalBlock(photo: currentPhoto)],
                origin: .edited,
                sourceFingerprint: fingerprint("r"),
                sourceEntryCount: 0,
                baseVersionID: firstVersionID,
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            for: day,
            userID: userID
        )
        _ = try await journalWorkspace.append(
            NewJournalVersion(
                title: "其他用户的照片日记",
                blocks: [JournalBlock(photo: otherPhoto)],
                origin: .edited,
                sourceFingerprint: fingerprint("s"),
                sourceEntryCount: 0
            ),
            for: day,
            userID: otherUserID
        )
        _ = try await dayWorkspace.deleteEntry(
            id: sourceEntry.id,
            userID: userID,
            expectedRevision: sourceEntry.revision,
            deletedAt: Date(timeIntervalSince1970: 300)
        )
        _ = try await dayWorkspace.deleteEntry(
            id: otherSourceEntry.id,
            userID: otherUserID,
            expectedRevision: otherSourceEntry.revision,
            deletedAt: Date(timeIntervalSince1970: 300)
        )

        let retainedPhotoIDs = try await dayWorkspace.photoIDs(userID: userID)
        let allPhotoIDs = try await dayWorkspace.allPhotoIDs()
        XCTAssertEqual(retainedPhotoIDs, Set([historicalPhoto.id, currentPhoto.id]))
        XCTAssertEqual(
            allPhotoIDs,
            Set([historicalPhoto.id, currentPhoto.id, otherPhoto.id])
        )
    }

    func testFourEntityStoreMigratesAndAllowsJournalAppend() async throws {
        let directory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("pre-journal.store")
        let createdAt = Date(timeIntervalSince1970: 1_768_435_200)
        try writePreJournalStore(storeURL: storeURL, createdAt: createdAt)

        let migratedContainer = try ModelContainerFactory.make(
            configurationName: "PreJournalMigration",
            storeURL: storeURL
        )
        let dayWorkspace = SwiftDataDayWorkspace(modelContainer: migratedContainer)
        let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: migratedContainer)
        let entries = try await dayWorkspace.entries(for: day, userID: userID)
        let journal = try await journalWorkspace.append(
            makeDraft(id: uuid(60), title: "迁移后的日记", text: "旧记录仍在"),
            for: day,
            userID: userID
        )

        XCTAssertEqual(entries.map(\.text), ["旧四实体 schema 中的记录"])
        XCTAssertEqual(journal.currentVersion.versionNumber, 1)
        XCTAssertEqual(journal.currentVersion.title, "迁移后的日记")
    }

    @MainActor
    func testCorruptedJournalScopeAndCrossUserVersionAreRejected() async throws {
        let first = try await populatedContainer(id: uuid(70))
        let firstContext = ModelContext(first)
        let journalRecord = try XCTUnwrap(
            try firstContext.fetch(FetchDescriptor<JournalRecord>()).first
        )
        journalRecord.userID = otherUserID
        try firstContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: first).journal(
                for: day,
                userID: userID
            )
            XCTFail("主记录用户字段损坏后不应读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(
                error,
                .invalidJournalScope(
                    JournalRecord.makeScopeKey(userID: userID, dayKey: day)
                )
            )
        }

        let second = try await populatedContainer(id: uuid(71))
        let secondContext = ModelContext(second)
        let versionRecord = try XCTUnwrap(
            try secondContext.fetch(FetchDescriptor<JournalVersionRecord>()).first
        )
        versionRecord.userID = otherUserID
        try secondContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: second).journal(
                for: day,
                userID: userID
            )
            XCTFail("版本用户字段损坏后不应读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .invalidVersionScope(uuid(71)))
        }
    }

    @MainActor
    func testInvalidOriginAndBlocksPayloadAreRejected() async throws {
        let first = try await populatedContainer(id: uuid(80))
        let firstContext = ModelContext(first)
        let originRecord = try XCTUnwrap(
            try firstContext.fetch(FetchDescriptor<JournalVersionRecord>()).first
        )
        originRecord.originRawValue = "unknown"
        try firstContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: first).journal(
                for: day,
                userID: userID
            )
            XCTFail("非法版本来源不应被读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .invalidVersionOrigin("unknown"))
        }

        let second = try await populatedContainer(id: uuid(81))
        let secondContext = ModelContext(second)
        let blocksRecord = try XCTUnwrap(
            try secondContext.fetch(FetchDescriptor<JournalVersionRecord>()).first
        )
        blocksRecord.blocksData = Data("{}".utf8)
        try secondContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: second).journal(
                for: day,
                userID: userID
            )
            XCTFail("损坏的 block payload 不应被读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .invalidBlocksData)
        }
    }

    @MainActor
    func testInvalidCurrentAndBaseVersionReferencesAreRejected() async throws {
        let first = try await populatedContainer(id: uuid(90))
        let firstContext = ModelContext(first)
        let journalRecord = try XCTUnwrap(
            try firstContext.fetch(FetchDescriptor<JournalRecord>()).first
        )
        let missingCurrentID = uuid(91)
        journalRecord.currentVersionID = missingCurrentID
        try firstContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: first).journal(
                for: day,
                userID: userID
            )
            XCTFail("断裂的 currentVersionID 不应被读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .invalidCurrentVersion(missingCurrentID))
        }

        let second = try await populatedContainer(id: uuid(92))
        let secondContext = ModelContext(second)
        let versionRecord = try XCTUnwrap(
            try secondContext.fetch(FetchDescriptor<JournalVersionRecord>()).first
        )
        let missingBaseID = uuid(93)
        versionRecord.baseVersionID = missingBaseID
        try secondContext.save()

        do {
            _ = try await SwiftDataJournalWorkspace(modelContainer: second).journal(
                for: day,
                userID: userID
            )
            XCTFail("断裂的 baseVersionID 不应被读取")
        } catch let error as JournalPersistenceError {
            XCTAssertEqual(error, .missingBaseVersion(missingBaseID))
        }
    }

    @MainActor
    func testTwoWorkspacesConcurrentFirstAppendCreateOneJournalAndUniqueVersions() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let firstWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        let secondWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        let firstID = uuid(100)
        let secondID = uuid(101)
        let requestedDay = day
        let requestedUserID = userID
        let firstDraft = makeDraft(id: firstID, title: "并发 A", text: "A")
        let secondDraft = makeDraft(id: secondID, title: "并发 B", text: "B")

        async let first = firstWorkspace.append(
            firstDraft,
            for: requestedDay,
            userID: requestedUserID
        )
        async let second = secondWorkspace.append(
            secondDraft,
            for: requestedDay,
            userID: requestedUserID
        )
        _ = try await (first, second)

        let loadedValue = try await firstWorkspace.journal(for: day, userID: userID)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(Set(loaded.allVersions.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(Set(loaded.allVersions.map(\.versionNumber)), Set([1, 2]))

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JournalRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JournalVersionRecord>()), 2)
    }

    @MainActor
    func testConcurrentReadsAndAppendsAcrossContextsReturnCompleteSnapshots() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let requestedDay = day
        let requestedUserID = userID
        let seedWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        _ = try await seedWorkspace.append(
            makeDraft(id: uuid(130), title: "初始版本", text: "初始正文"),
            for: requestedDay,
            userID: requestedUserID
        )

        let drafts = (0..<20).map { index in
            makeDraft(
                id: uuid(UInt8(131 + index)),
                title: "并发版本 \(index)",
                text: String(repeating: "正文 \(index) ", count: 32),
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
        }
        let writerWorkspaces = drafts.map { _ in
            SwiftDataJournalWorkspace(modelContainer: container)
        }
        let readerWorkspaces = (0..<6).map { _ in
            SwiftDataJournalWorkspace(modelContainer: container)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workspace in readerWorkspaces {
                group.addTask {
                    for _ in 0..<80 {
                        guard let journal = try await workspace.journal(
                            for: requestedDay,
                            userID: requestedUserID
                        ) else {
                            throw ConcurrentSnapshotError.missingJournal
                        }
                        let versions = journal.allVersions
                        let numbers = versions.map(\.versionNumber)
                        guard
                            !versions.isEmpty,
                            journal.currentVersion.versionNumber == versions.count,
                            Set(numbers) == Set(1...versions.count)
                        else {
                            throw ConcurrentSnapshotError.mixedVersionSet(numbers)
                        }
                        await Task.yield()
                    }
                }
            }
            for (workspace, draft) in zip(writerWorkspaces, drafts) {
                group.addTask {
                    _ = try await workspace.append(
                        draft,
                        for: requestedDay,
                        userID: requestedUserID
                    )
                }
            }
            try await group.waitForAll()
        }

        let reloadedValue = try await seedWorkspace.journal(
            for: requestedDay,
            userID: requestedUserID
        )
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.currentVersion.versionNumber, drafts.count + 1)
        XCTAssertEqual(Set(reloaded.allVersions.map(\.id)), Set(drafts.map(\.id) + [uuid(130)]))
    }

    @MainActor
    private func populatedContainer(id: UUID) async throws -> ModelContainer {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        _ = try await workspace.append(
            makeDraft(id: id, title: "可损坏的版本", text: "正文"),
            for: day,
            userID: userID
        )
        return container
    }

    private func writePersistentHistory(
        storeURL: URL,
        firstID: UUID,
        secondID: UUID
    ) async throws {
        let container = try ModelContainerFactory.make(
            configurationName: "JournalRestart",
            storeURL: storeURL
        )
        let workspace = SwiftDataJournalWorkspace(modelContainer: container)
        _ = try await workspace.append(
            makeDraft(id: firstID, title: "磁盘第一版", text: "第一版"),
            for: day,
            userID: userID
        )
        _ = try await workspace.append(
            makeDraft(
                id: secondID,
                title: "磁盘第二版",
                text: "第二版",
                origin: .edited,
                baseVersionID: firstID
            ),
            for: day,
            userID: userID
        )
    }

    private func writePreJournalStore(storeURL: URL, createdAt: Date) throws {
        let schema = Schema([
            EntryRecord.self,
            PhotoAttachmentRecord.self,
            VoiceAttachmentRecord.self,
            DayRecord.self,
        ])
        let configuration = ModelConfiguration(
            "PreJournalMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(
            EntryRecord(
                id: uuid(110),
                userID: userID,
                dayKeyRawValue: day.storageValue,
                createdAt: createdAt,
                updatedAt: createdAt,
                creationTimeZoneIdentifier: "Asia/Shanghai",
                text: "旧四实体 schema 中的记录"
            )
        )
        try context.save()
    }

    private func makeDraft(
        id: UUID,
        title: String,
        text: String,
        origin: JournalVersionOrigin = .edited,
        fingerprint: JournalSourceFingerprint? = nil,
        baseVersionID: UUID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_768_435_200)
    ) -> NewJournalVersion {
        NewJournalVersion(
            id: id,
            title: title,
            blocks: [JournalBlock(id: uuid(120), text: text)],
            origin: origin,
            sourceFingerprint: fingerprint ?? self.fingerprint("f"),
            sourceEntryCount: 1,
            baseVersionID: baseVersionID,
            generatorIdentifier: "local.rule-based.v1",
            createdAt: createdAt
        )
    }

    private func createEntryWithPhotos(
        ids: [UUID],
        userID: UUID,
        container: ModelContainer
    ) async throws -> Entry {
        var calendar = Calendar(identifier: .gregorian)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.timeZone = utc
        let instant = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: day.year,
                    month: day.month,
                    day: day.day,
                    hour: 12
                )
            )
        )
        let photos = ids.enumerated().map { index, id in
            NewPhotoAttachment(
                id: id,
                annotationText: "原始记录批注 \(index + 1)",
                contentTypeIdentifier: "public.heic",
                pixelWidth: 4_032,
                pixelHeight: 3_024,
                byteCount: 8_192,
                originalRelativePath: "Photos/\(id.uuidString)/original.heic",
                thumbnailRelativePath: "Photos/\(id.uuidString)/thumbnail.jpg"
            )
        }
        return try await SwiftDataDayWorkspace(modelContainer: container).create(
            NewEntry(text: "日记照片来源", photos: photos),
            userID: userID,
            context: RecordingContext(instant: instant, timeZone: utc)
        )
    }

    private func fingerprint(_ character: Character) -> JournalSourceFingerprint {
        JournalSourceFingerprint(rawValue: String(repeating: character, count: 64))
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeNotesJournalTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private enum ConcurrentSnapshotError: Error {
        case missingJournal
        case mixedVersionSet([Int])
    }
}
