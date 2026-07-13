import Foundation
import SwiftData

@ModelActor
actor SwiftDataDayWorkspace: DayWorkspace {
    func createText(
        _ draft: NewTextEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        let dayKey = DayKey(containing: context.instant, in: context.timeZone)
        let record = EntryRecord(
            id: UUID(),
            userID: userID,
            dayKeyRawValue: dayKey.storageValue,
            createdAt: context.instant,
            updatedAt: context.instant,
            creationTimeZoneIdentifier: context.timeZone.identifier,
            text: draft.text
        )

        modelContext.insert(record)
        do {
            try modelContext.save()
            return try record.domainEntry()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        let requestedUserID = userID
        let requestedDayKey = day.storageValue
        let descriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            },
            sortBy: [SortDescriptor(\EntryRecord.createdAt, order: .reverse)]
        )

        return try modelContext.fetch(descriptor).map { try $0.domainEntry() }
    }
}
