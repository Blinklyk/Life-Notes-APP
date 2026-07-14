import Foundation
import SwiftData
import XCTest
@testable import LifeNotes

final class DayStatePersistenceTests: XCTestCase {
    private let userID = UUID(uuidString: "21125C06-A44D-49DC-A4D6-C0567915AC6D")!
    private let otherUserID = UUID(uuidString: "2E2805EE-0A9C-44C5-916A-A8279F8E5A72")!
    private let day = DayKey(year: 2026, month: 7, day: 15)!

    func testDailyFeelingUsesStableOneToFiveRawValuesAndChineseLabels() {
        let expected: [(DailyFeeling, Int, String)] = [
            (.veryLow, 1, "很低落"),
            (.low, 2, "低落"),
            (.calm, 3, "平静"),
            (.happy, 4, "开心"),
            (.veryHappy, 5, "很开心"),
        ]

        XCTAssertEqual(DailyFeeling.allCases.count, 5)
        for (feeling, rawValue, label) in expected {
            XCTAssertEqual(feeling.rawValue, rawValue)
            XCTAssertEqual(DailyFeeling(rawValue: rawValue), feeling)
            XCTAssertEqual(feeling.label, label)
        }
        XCTAssertNil(DailyFeeling(rawValue: 0))
        XCTAssertNil(DailyFeeling(rawValue: 6))
    }

    func testAllFeelingLevelsRoundTripAndUseOneStableScopeRecord() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        for (index, feeling) in DailyFeeling.allCases.enumerated() {
            let updatedAt = Date(timeIntervalSince1970: 1_768_435_200 + Double(index))
            let updated = try await workspace.setFeeling(
                feeling,
                for: day,
                userID: userID,
                updatedAt: updatedAt
            )
            let reloaded = try await workspace.dayState(for: day, userID: userID)

            XCTAssertEqual(updated.feeling, feeling)
            XCTAssertEqual(updated.feelingUpdatedAt, updatedAt)
            XCTAssertEqual(reloaded, updated)
        }

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<DayRecord>())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            record.scopeKey,
            "\(userID.uuidString.lowercased()):\(day.storageValue)"
        )
    }

    func testStateCanExistWithoutEntryAndRemainsUserIsolated() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let importantUpdatedAt = Date(timeIntervalSince1970: 1_768_435_210)

        let entries = try await workspace.entries(for: day, userID: userID)
        let initialState = try await workspace.dayState(for: day, userID: userID)
        let updatedState = try await workspace.setImportant(
            true,
            for: day,
            userID: userID,
            updatedAt: importantUpdatedAt
        )
        let otherUsersState = try await workspace.dayState(
            for: day,
            userID: otherUserID
        )

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(initialState, DayState(dayKey: day))
        XCTAssertEqual(
            updatedState,
            DayState(
                dayKey: day,
                isImportant: true,
                importantUpdatedAt: importantUpdatedAt
            )
        )
        XCTAssertEqual(otherUsersState, DayState(dayKey: day))
    }

    func testSettersAndClearFeelingOnlyMutateTheirOwnFields() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let firstFeelingUpdate = Date(timeIntervalSince1970: 1_768_435_220)
        let importantUpdate = Date(timeIntervalSince1970: 1_768_435_230)
        let clearedFeelingUpdate = Date(timeIntervalSince1970: 1_768_435_240)

        _ = try await workspace.setFeeling(
            .happy,
            for: day,
            userID: userID,
            updatedAt: firstFeelingUpdate
        )
        let importantState = try await workspace.setImportant(
            true,
            for: day,
            userID: userID,
            updatedAt: importantUpdate
        )
        let clearedState = try await workspace.setFeeling(
            nil,
            for: day,
            userID: userID,
            updatedAt: clearedFeelingUpdate
        )

        XCTAssertEqual(importantState.feeling, .happy)
        XCTAssertEqual(importantState.feelingUpdatedAt, firstFeelingUpdate)
        XCTAssertTrue(importantState.isImportant)
        XCTAssertEqual(importantState.importantUpdatedAt, importantUpdate)

        XCTAssertNil(clearedState.feeling)
        XCTAssertEqual(clearedState.feelingUpdatedAt, clearedFeelingUpdate)
        XCTAssertTrue(clearedState.isImportant)
        XCTAssertEqual(clearedState.importantUpdatedAt, importantUpdate)
    }

    func testConcurrentFirstUpdatesMergeFeelingAndImportant() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let feelingWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let importantWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let requestedDay = day
        let requestedUserID = userID
        let feelingUpdatedAt = Date(timeIntervalSince1970: 1_768_435_245)
        let importantUpdatedAt = Date(timeIntervalSince1970: 1_768_435_246)

        async let feelingState = feelingWorkspace.setFeeling(
            .happy,
            for: requestedDay,
            userID: requestedUserID,
            updatedAt: feelingUpdatedAt
        )
        async let importantState = importantWorkspace.setImportant(
            true,
            for: requestedDay,
            userID: requestedUserID,
            updatedAt: importantUpdatedAt
        )
        _ = try await (feelingState, importantState)

        let mergedState = try await feelingWorkspace.dayState(
            for: requestedDay,
            userID: requestedUserID
        )

        XCTAssertEqual(mergedState.feeling, .happy)
        XCTAssertTrue(mergedState.isImportant)
        XCTAssertEqual(mergedState.feelingUpdatedAt, feelingUpdatedAt)
        XCTAssertEqual(mergedState.importantUpdatedAt, importantUpdatedAt)
    }

    @MainActor
    func testMismatchedScopeIsRejected() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(
            DayRecord(
                scopeKey: DayRecord.makeScopeKey(userID: userID, dayKey: day),
                userID: otherUserID,
                dayKeyRawValue: DayKey(year: 2026, month: 7, day: 14)!.storageValue
            )
        )
        try context.save()
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        do {
            _ = try await workspace.dayState(for: day, userID: userID)
            XCTFail("范围字段不一致的每日状态不应被读取")
        } catch let PersistenceMappingError.invalidDayRecordScope(value) {
            XCTAssertEqual(
                value,
                DayRecord.makeScopeKey(userID: userID, dayKey: day)
            )
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }

    @MainActor
    func testInvalidFeelingIsRejectedBeforeImportantMutationIsSaved() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(
            DayRecord(
                scopeKey: DayRecord.makeScopeKey(userID: userID, dayKey: day),
                userID: userID,
                dayKeyRawValue: day.storageValue,
                feelingRawValue: 99,
                isImportant: false
            )
        )
        try context.save()
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        do {
            _ = try await workspace.setImportant(
                true,
                for: day,
                userID: userID,
                updatedAt: Date(timeIntervalSince1970: 1_768_435_247)
            )
            XCTFail("非法感受值不应允许写入其他字段")
        } catch PersistenceMappingError.invalidDailyFeeling(99) {
            // 预期错误。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        let verificationContext = ModelContext(container)
        let records = try verificationContext.fetch(FetchDescriptor<DayRecord>())
        XCTAssertFalse(try XCTUnwrap(records.first).isImportant)
    }

    func testDayStatePersistsAcrossStoreReopen() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("day-state.store")
        let feelingUpdatedAt = Date(timeIntervalSince1970: 1_768_435_250)
        let importantUpdatedAt = Date(timeIntervalSince1970: 1_768_435_260)

        try await writePersistentState(
            storeURL: storeURL,
            feelingUpdatedAt: feelingUpdatedAt,
            importantUpdatedAt: importantUpdatedAt
        )

        let reopenedContainer = try ModelContainerFactory.make(
            configurationName: "DayStateRestart",
            storeURL: storeURL
        )
        let reopenedWorkspace = SwiftDataDayWorkspace(modelContainer: reopenedContainer)
        let restored = try await reopenedWorkspace.dayState(for: day, userID: userID)

        XCTAssertEqual(
            restored,
            DayState(
                dayKey: day,
                feeling: .veryHappy,
                isImportant: true,
                feelingUpdatedAt: feelingUpdatedAt,
                importantUpdatedAt: importantUpdatedAt
            )
        )
    }

    func testStoreWithoutDayRecordMigratesAndPreservesExistingEntries() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("pre-day-state.store")
        let createdAt = Date(timeIntervalSince1970: 1_768_435_200)

        try writePreDayStateStore(storeURL: storeURL, createdAt: createdAt)

        let migratedContainer = try ModelContainerFactory.make(
            configurationName: "PreDayStateMigration",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: migratedContainer)
        let entries = try await workspace.entries(for: day, userID: userID)
        let initialState = try await workspace.dayState(for: day, userID: userID)
        let feelingUpdatedAt = Date(timeIntervalSince1970: 1_768_435_270)
        let updatedState = try await workspace.setFeeling(
            .calm,
            for: day,
            userID: userID,
            updatedAt: feelingUpdatedAt
        )

        XCTAssertEqual(entries.map(\.text), ["旧 schema 中的记录"])
        XCTAssertEqual(initialState, DayState(dayKey: day))
        XCTAssertEqual(updatedState.feeling, .calm)
        XCTAssertEqual(updatedState.feelingUpdatedAt, feelingUpdatedAt)
    }

    private func writePersistentState(
        storeURL: URL,
        feelingUpdatedAt: Date,
        importantUpdatedAt: Date
    ) async throws {
        let container = try ModelContainerFactory.make(
            configurationName: "DayStateRestart",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        _ = try await workspace.setFeeling(
            .veryHappy,
            for: day,
            userID: userID,
            updatedAt: feelingUpdatedAt
        )
        _ = try await workspace.setImportant(
            true,
            for: day,
            userID: userID,
            updatedAt: importantUpdatedAt
        )
    }

    private func writePreDayStateStore(storeURL: URL, createdAt: Date) throws {
        let schema = Schema([
            EntryRecord.self,
            PhotoAttachmentRecord.self,
            VoiceAttachmentRecord.self,
        ])
        let configuration = ModelConfiguration(
            "PreDayStateMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(
            EntryRecord(
                id: UUID(),
                userID: userID,
                dayKeyRawValue: day.storageValue,
                createdAt: createdAt,
                updatedAt: createdAt,
                creationTimeZoneIdentifier: "Asia/Shanghai",
                text: "旧 schema 中的记录"
            )
        )
        try context.save()
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DayStatePersistenceTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
