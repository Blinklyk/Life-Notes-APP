import Foundation
import SwiftData

@ModelActor
actor SwiftDataDayWorkspace: DayWorkspace {
    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        let dayKey = DayKey(containing: context.instant, in: context.timeZone)
        let entryID = UUID()
        let record = EntryRecord(
            id: entryID,
            userID: userID,
            sourceDraftID: draft.sourceDraftID,
            dayKeyRawValue: dayKey.storageValue,
            createdAt: context.instant,
            updatedAt: context.instant,
            creationTimeZoneIdentifier: context.timeZone.identifier,
            text: draft.text
        )
        let photoRecords = draft.photos.enumerated().map { sortIndex, photo in
            PhotoAttachmentRecord(
                id: photo.id,
                entryID: entryID,
                userID: userID,
                dayKeyRawValue: dayKey.storageValue,
                sortIndex: sortIndex,
                annotationText: photo.annotationText,
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        }

        modelContext.insert(record)
        for photoRecord in photoRecords {
            modelContext.insert(photoRecord)
        }

        do {
            try modelContext.save()
            return try record.domainEntry(
                photos: photoRecords.map { $0.domainAttachment() }
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        let requestedUserID = userID
        let requestedDayKey = day.storageValue
        let entryDescriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            },
            sortBy: [SortDescriptor(\EntryRecord.createdAt, order: .reverse)]
        )
        let photoDescriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            }
        )

        let entryRecords = try modelContext.fetch(entryDescriptor)
        let photoRecords = try modelContext.fetch(photoDescriptor)
        let photosByEntryID = Dictionary(grouping: photoRecords, by: \PhotoAttachmentRecord.entryID)

        let entries = try entryRecords.map { record in
            let photos = photosByEntryID[record.id, default: []]
                .sorted { lhs, rhs in
                    if lhs.sortIndex != rhs.sortIndex {
                        return lhs.sortIndex < rhs.sortIndex
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .map { $0.domainAttachment() }
            return try record.domainEntry(photos: photos)
        }

        return entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool {
        let requestedDraftID = id
        let requestedUserID = userID
        var descriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.sourceDraftID == requestedDraftID
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func photoIDs(userID: UUID) async throws -> Set<UUID> {
        let requestedUserID = userID
        let descriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { record in
                record.userID == requestedUserID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    func allPhotoIDs() async throws -> Set<UUID> {
        let descriptor = FetchDescriptor<PhotoAttachmentRecord>()
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }
}
