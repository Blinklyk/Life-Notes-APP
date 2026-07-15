import Combine
import Foundation

@MainActor
final class EntryLibraryModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    struct MutationEvent: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case updated
            case deleted
        }

        let id = UUID()
        let dayKey: DayKey
        let entryID: UUID
        let kind: Kind
    }

    @Published private(set) var query = ""
    @Published private(set) var results: [Entry] = []
    @Published private(set) var isSearching = false
    @Published private(set) var selectedEntry: Entry?
    @Published private(set) var editingEntry: Entry?
    @Published private(set) var busyEntryIDs: Set<UUID> = []
    @Published private(set) var mutationEvent: MutationEvent?
    @Published var alert: Message?
    @Published var notice: Message?

    private let workspace: any DayWorkspace
    private let userID: UUID
    private let photoLibrary: any PhotoLibrary
    private let audioLibrary: any AudioLibrary
    private let now: @Sendable () -> Date

    private var searchRequestGeneration = 0
    private var searchPublicationGeneration = 0
    private var editingPreparationGeneration = 0
    private var mutationGenerations: [UUID: Int] = [:]
    private var deletedEntryIDs: Set<UUID> = []

    init(
        workspace: any DayWorkspace,
        userID: UUID,
        photoLibrary: any PhotoLibrary,
        audioLibrary: any AudioLibrary,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workspace = workspace
        self.userID = userID
        self.photoLibrary = photoLibrary
        self.audioLibrary = audioLibrary
        self.now = now
    }

    func search(matching rawQuery: String) async {
        let normalizedQuery = Self.normalized(rawQuery)
        searchRequestGeneration += 1
        let requestGeneration = searchRequestGeneration
        let publicationGeneration = searchPublicationGeneration
        if query != normalizedQuery {
            results = []
        }
        query = normalizedQuery

        guard !normalizedQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        defer {
            if searchRequestGeneration == requestGeneration {
                isSearching = false
            }
        }

        do {
            let loaded = try await workspace.searchEntries(
                matching: normalizedQuery,
                userID: userID
            )
            guard
                !Task.isCancelled,
                searchRequestGeneration == requestGeneration,
                searchPublicationGeneration == publicationGeneration,
                query == normalizedQuery
            else {
                return
            }

            results = try validatedSearchResults(loaded).filter {
                !deletedEntryIDs.contains($0.id)
            }
        } catch {
            guard
                !Task.isCancelled,
                searchRequestGeneration == requestGeneration,
                searchPublicationGeneration == publicationGeneration,
                query == normalizedQuery
            else {
                return
            }
            results = []
            alert = Message(message: "暂时无法搜索随心记录，请稍后重试。")
        }
    }

    func select(_ entry: Entry?) {
        guard let entry else {
            cancelEditingPreparation()
            selectedEntry = nil
            editingEntry = nil
            return
        }
        guard entry.userID == userID, !deletedEntryIDs.contains(entry.id) else {
            return
        }
        if editingEntry?.id != entry.id {
            editingEntry = nil
        }
        selectedEntry = preferredEntry(entry)
    }

    func beginEditing(_ entry: Entry) {
        cancelEditingPreparation()
        publishEditingEntry(entry)
    }

    func prepareEditing(
        _ entry: Entry,
        resolveCurrentEntry: @MainActor (Entry) async -> Entry
    ) async {
        guard
            entry.userID == userID,
            !deletedEntryIDs.contains(entry.id),
            !busyEntryIDs.contains(entry.id)
        else {
            return
        }

        editingPreparationGeneration += 1
        let generation = editingPreparationGeneration
        let current = await resolveCurrentEntry(entry)
        guard
            !Task.isCancelled,
            editingPreparationGeneration == generation,
            current.id == entry.id,
            current.userID == userID,
            !deletedEntryIDs.contains(current.id),
            !busyEntryIDs.contains(current.id)
        else {
            return
        }

        publishEditingEntry(current)
    }

    func cancelEditingPreparation() {
        editingPreparationGeneration += 1
    }

    func cancelEditing() {
        cancelEditingPreparation()
        editingEntry = nil
    }

    @discardableResult
    func updateEntry(id: UUID, edit: EntryEdit) async -> Bool {
        guard !deletedEntryIDs.contains(id) else {
            alert = Message(message: "这条随心记录已被删除，无法继续编辑。")
            removeEntryFromPublishedState(id: id)
            return false
        }

        let token = beginMutation(for: id)
        defer { finishMutation(token) }

        do {
            let updated = try await workspace.updateEntry(
                id: id,
                userID: userID,
                edit: edit,
                updatedAt: now()
            )
            guard isCurrent(token), !deletedEntryIDs.contains(id) else {
                return false
            }
            guard
                updated.id == id,
                updated.userID == userID,
                updated.revision >= edit.expectedRevision
            else {
                throw EntryLibraryModelError.invalidMutationResult
            }

            invalidatePendingSearch()
            publishUpdatedEntry(updated)
            mutationEvent = MutationEvent(
                dayKey: updated.dayKey,
                entryID: updated.id,
                kind: .updated
            )
            return true
        } catch {
            guard isCurrent(token), !deletedEntryIDs.contains(id) else {
                return false
            }
            handleMutationError(
                error,
                entryID: id,
                knownDayKey: currentEntry(for: id)?.dayKey,
                operation: .update
            )
            return false
        }
    }

    @discardableResult
    func deleteEntry(_ entry: Entry) async -> Bool {
        await deleteEntry(entry, preparedEntry: entry)
    }

    @discardableResult
    func deleteEntry(_ confirmedEntry: Entry, preparedEntry: Entry) async -> Bool {
        guard confirmedEntry.userID == userID else {
            alert = Message(message: "找不到要删除的随心记录。")
            return false
        }
        guard
            preparedEntry.id == confirmedEntry.id,
            preparedEntry.userID == confirmedEntry.userID,
            preparedEntry.dayKey == confirmedEntry.dayKey
        else {
            alert = Message(message: "找不到要删除的随心记录。")
            return false
        }
        guard preparedEntry.revision == confirmedEntry.revision else {
            invalidatePendingSearch()
            publishUpdatedEntry(preparedEntry)
            mutationEvent = MutationEvent(
                dayKey: preparedEntry.dayKey,
                entryID: preparedEntry.id,
                kind: .updated
            )
            alert = Message(message: "这条随心记录已在其他位置更新，请刷新后再试。")
            return false
        }

        return await deleteConfirmedEntry(confirmedEntry)
    }

    private func deleteConfirmedEntry(_ entry: Entry) async -> Bool {
        guard entry.userID == userID else {
            alert = Message(message: "找不到要删除的随心记录。")
            return false
        }
        guard !deletedEntryIDs.contains(entry.id) else {
            removeEntryFromPublishedState(id: entry.id)
            return true
        }

        let token = beginMutation(for: entry.id)
        defer { finishMutation(token) }
        let deletedAt = now()
        notice = nil

        do {
            let deleted = try await workspace.deleteEntry(
                id: entry.id,
                userID: userID,
                expectedRevision: entry.revision,
                deletedAt: deletedAt
            )
            let deletedDay = deleted.id == entry.id && deleted.userID == userID
                ? deleted.dayKey
                : entry.dayKey

            publishDeletedEntry(id: entry.id, dayKey: deletedDay)
            if deleted.id == entry.id, deleted.userID == userID {
                await removeUnreferencedMedia(from: deleted)
            } else {
                notice = Message(
                    message: "记录已删除，但本地媒体暂时无法清理，之后会自动重试。"
                )
            }
            busyEntryIDs.remove(entry.id)
            return true
        } catch {
            guard isCurrent(token), !deletedEntryIDs.contains(entry.id) else {
                return false
            }
            handleMutationError(
                error,
                entryID: entry.id,
                knownDayKey: entry.dayKey,
                operation: .delete
            )
            return false
        }
    }

    private func beginMutation(for entryID: UUID) -> MutationToken {
        mutationGenerations[entryID, default: 0] += 1
        let token = MutationToken(
            entryID: entryID,
            generation: mutationGenerations[entryID, default: 0]
        )
        busyEntryIDs.insert(entryID)
        return token
    }

    private func finishMutation(_ token: MutationToken) {
        guard isCurrent(token) else {
            return
        }
        busyEntryIDs.remove(token.entryID)
    }

    private func isCurrent(_ token: MutationToken) -> Bool {
        mutationGenerations[token.entryID] == token.generation
    }

    private func publishUpdatedEntry(_ entry: Entry) {
        if let index = results.firstIndex(where: { $0.id == entry.id }) {
            if matchesCurrentQuery(entry) {
                results[index] = entry
            } else {
                results.remove(at: index)
            }
        } else if matchesCurrentQuery(entry) {
            results.append(entry)
            results.sort(by: Self.searchOrder)
        }

        if selectedEntry?.id == entry.id {
            selectedEntry = entry
        }
        if editingEntry?.id == entry.id {
            editingEntry = nil
        }
    }

    private func publishEditingEntry(_ entry: Entry) {
        guard
            entry.userID == userID,
            !deletedEntryIDs.contains(entry.id),
            !busyEntryIDs.contains(entry.id)
        else {
            return
        }
        let current = preferredEntry(entry)
        selectedEntry = current
        editingEntry = current
    }

    private func publishDeletedEntry(id: UUID, dayKey: DayKey) {
        cancelEditingPreparation()
        deletedEntryIDs.insert(id)
        mutationGenerations[id, default: 0] += 1
        invalidatePendingSearch()
        removeEntryFromPublishedState(id: id)
        mutationEvent = MutationEvent(dayKey: dayKey, entryID: id, kind: .deleted)
    }

    private func removeEntryFromPublishedState(id: UUID) {
        results.removeAll { $0.id == id }
        if selectedEntry?.id == id {
            selectedEntry = nil
        }
        if editingEntry?.id == id {
            editingEntry = nil
        }
    }

    private func handleMutationError(
        _ error: Error,
        entryID: UUID,
        knownDayKey: DayKey?,
        operation: MutationOperation
    ) {
        if let workspaceError = error as? DayWorkspaceError {
            switch workspaceError {
            case .entryNotFound:
                let dayKey = currentEntry(for: entryID)?.dayKey ?? knownDayKey
                deletedEntryIDs.insert(entryID)
                invalidatePendingSearch()
                removeEntryFromPublishedState(id: entryID)
                if let dayKey {
                    mutationEvent = MutationEvent(
                        dayKey: dayKey,
                        entryID: entryID,
                        kind: .deleted
                    )
                }
                alert = Message(message: "这条随心记录已不存在，当前内容已刷新。")
                return
            case .entryRevisionConflict:
                alert = Message(message: "这条随心记录已在其他位置更新，请刷新后再试。")
                return
            default:
                break
            }
        }

        switch operation {
        case .update:
            alert = Message(message: "暂时无法保存这条随心记录，请稍后重试。")
        case .delete:
            alert = Message(message: "暂时无法删除这条随心记录，请稍后重试。")
        }
    }

    private func removeUnreferencedMedia(from deletedEntry: Entry) async {
        var photoIDs: Set<UUID>?
        var audioIDs: Set<UUID>?
        var referenceReadFailed = false
        do {
            photoIDs = try await workspace.allPhotoIDs()
        } catch {
            referenceReadFailed = true
        }
        do {
            audioIDs = try await workspace.allRetainedVoiceIDs()
        } catch {
            referenceReadFailed = true
        }
        guard
            !referenceReadFailed,
            let photoIDs,
            let audioIDs
        else {
            notice = Message(
                message: "记录已删除，但本地媒体暂时无法清理，之后会自动重试。"
            )
            return
        }

        var cleanupFailed = false
        for photo in deletedEntry.photos where !photoIDs.contains(photo.id) {
            let importedPhoto = ImportedPhoto(
                id: photo.id,
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
            do {
                try await photoLibrary.removePhoto(importedPhoto)
            } catch {
                cleanupFailed = true
            }
        }

        for voice in deletedEntry.voices where
            voice.originalRelativePath != nil && !audioIDs.contains(voice.id) {
            do {
                try await audioLibrary.removeAudio(id: voice.id)
            } catch {
                cleanupFailed = true
            }
        }

        if cleanupFailed {
            notice = Message(
                message: "记录已删除，但部分本地媒体暂时未能清理，之后会自动重试。"
            )
        }
    }

    private func validatedSearchResults(_ loaded: [Entry]) throws -> [Entry] {
        var seen: Set<UUID> = []
        for entry in loaded {
            guard entry.userID == userID, seen.insert(entry.id).inserted else {
                throw EntryLibraryModelError.invalidSearchResults
            }
        }
        return loaded
    }

    private func invalidatePendingSearch() {
        searchRequestGeneration += 1
        searchPublicationGeneration += 1
        isSearching = false
    }

    private func currentEntry(for id: UUID) -> Entry? {
        ([selectedEntry, editingEntry].compactMap { $0 }
            + results)
            .filter { $0.id == id }
            .max(by: Self.isOlder)
    }

    private func preferredEntry(_ candidate: Entry) -> Entry {
        guard let current = currentEntry(for: candidate.id) else {
            return candidate
        }
        return Self.isOlder(candidate, current) ? current : candidate
    }

    private static func isOlder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.revision != rhs.revision {
            return lhs.revision < rhs.revision
        }
        return lhs.updatedAt < rhs.updatedAt
    }

    private func matchesCurrentQuery(_ entry: Entry) -> Bool {
        EntrySearch.matches(entry, query: query)
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

private struct MutationToken {
    let entryID: UUID
    let generation: Int
}

private enum MutationOperation {
    case update
    case delete
}

private enum EntryLibraryModelError: Error {
    case invalidSearchResults
    case invalidMutationResult
}
