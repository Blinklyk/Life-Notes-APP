import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let maxPhotosPerEntry = 20

    enum Route: Equatable {
        case capture
        case today
    }

    struct Alert: Identifiable {
        let id = UUID()
        let message: String
    }

    struct DraftPhoto: Identifiable, Equatable {
        enum State: Equatable {
            case importing
            case ready(ImportedPhoto)
            case failed
        }

        let id: UUID
        var state: State
        var annotationText: String
    }

    @Published var draftText = "" {
        didSet { scheduleDraftPersistence() }
    }
    @Published private(set) var draftPhotos: [DraftPhoto] = []
    @Published private(set) var route: Route = .capture
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var todayDate: Date
    @Published private(set) var todayTimeZone: TimeZone
    @Published private(set) var isLoadingToday = false
    @Published private(set) var isSaving = false
    @Published private(set) var isRestoringDraft = true
    @Published private(set) var isCaptureDraftAvailable = true
    @Published private(set) var notice: String?
    @Published var alert: Alert?

    let photoLibrary: any PhotoLibrary

    private let workspace: any DayWorkspace
    private let captureDraftStore: any CaptureDraftStore
    private let userID: UUID
    private let now: @Sendable () -> Date
    private let currentTimeZone: @Sendable () -> TimeZone
    private var noticeTask: Task<Void, Never>?
    private var draftPersistenceTask: Task<Void, Never>?
    private var draftPersistenceGeneration = 0
    private var suppressDraftPersistence = false
    private var reportedDraftPersistenceError = false
    private var captureDraftID = UUID()
    private var canPersistCaptureDraft = true

    init(
        workspace: any DayWorkspace,
        photoLibrary: any PhotoLibrary,
        captureDraftStore: any CaptureDraftStore,
        userID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.workspace = workspace
        self.photoLibrary = photoLibrary
        self.captureDraftStore = captureDraftStore
        self.userID = userID
        self.now = now
        self.currentTimeZone = currentTimeZone

        let initialDate = now()
        todayDate = initialDate
        todayTimeZone = currentTimeZone()

        Task { [weak self] in
            guard let self else {
                return
            }
            let canReconcilePhotoStorage = await self.restoreCaptureDraft()
            await self.refreshToday(showError: false)
            if canReconcilePhotoStorage {
                await self.reconcilePhotoStorage()
            }
        }
    }

    var canSaveDraft: Bool {
        guard isCaptureDraftAvailable, !isSaving, !isRestoringDraft else {
            return false
        }

        var readyPhotoCount = 0
        for photo in draftPhotos {
            switch photo.state {
            case .importing, .failed:
                return false
            case .ready:
                readyPhotoCount += 1
            }
        }

        let hasText = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || readyPhotoCount > 0
    }

    var isImportingPhotos: Bool {
        draftPhotos.contains { photo in
            if case .importing = photo.state {
                return true
            }
            return false
        }
    }

    var remainingPhotoCapacity: Int {
        max(0, Self.maxPhotosPerEntry - draftPhotos.count)
    }

    var canAddPhoto: Bool {
        isCaptureDraftAvailable
            && !isSaving
            && !isRestoringDraft
            && !isImportingPhotos
            && remainingPhotoCapacity > 0
    }

    @discardableResult
    func beginPhotoImport() -> UUID? {
        guard !isSaving, !isRestoringDraft, remainingPhotoCapacity > 0 else {
            return nil
        }
        let id = UUID()
        draftPhotos.append(
            DraftPhoto(id: id, state: .importing, annotationText: "")
        )
        scheduleDraftPersistence()
        return id
    }

    func completePhotoImport(id: UUID, photo: ImportedPhoto) {
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            Task {
                try? await photoLibrary.removePhoto(photo)
            }
            return
        }

        draftPhotos[index].state = .ready(photo)
        scheduleDraftPersistence()
    }

    func failPhotoImport(id: UUID) {
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }
        draftPhotos[index].state = .failed
        scheduleDraftPersistence()
    }

    func removeDraftPhoto(id: UUID) {
        guard !isSaving else {
            return
        }
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedPhoto = draftPhotos.remove(at: index)
        persistDraftAfterRemovingPhoto(removedPhoto)
    }

    func updatePhotoAnnotation(id: UUID, text: String) {
        guard !isSaving else {
            return
        }
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }
        draftPhotos[index].annotationText = text
        scheduleDraftPersistence()
    }

    func showCapture() {
        route = .capture
    }

    func showToday() {
        route = .today
        Task { [weak self] in
            await self?.refreshToday()
        }
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard isCaptureDraftAvailable else {
            alert = Alert(message: "草稿暂时无法读取。为避免覆盖原内容，请重新打开 App 后再试。")
            return false
        }
        guard !isSaving else {
            return false
        }

        let photos: [NewPhotoAttachment]
        do {
            photos = try draftPhotos.map { draftPhoto in
                guard case let .ready(photo) = draftPhoto.state else {
                    throw EntryValidationError.emptyEntry
                }
                return NewPhotoAttachment(
                    id: photo.id,
                    annotationText: draftPhoto.annotationText,
                    contentTypeIdentifier: photo.contentTypeIdentifier,
                    pixelWidth: photo.pixelWidth,
                    pixelHeight: photo.pixelHeight,
                    byteCount: photo.byteCount,
                    originalRelativePath: photo.originalRelativePath,
                    thumbnailRelativePath: photo.thumbnailRelativePath
                )
            }
        } catch {
            alert = Alert(message: "请先移除导入失败的照片，或等待照片导入完成。")
            return false
        }

        let draft: NewEntry
        do {
            draft = try NewEntry(
                sourceDraftID: captureDraftID,
                text: draftText,
                photos: photos
            )
        } catch {
            alert = Alert(message: error.localizedDescription)
            return false
        }

        isSaving = true
        defer { isSaving = false }

        let recordingContext = RecordingContext(
            instant: now(),
            timeZone: currentTimeZone()
        )

        let entry: Entry
        do {
            entry = try await workspace.create(
                draft,
                userID: userID,
                context: recordingContext
            )
        } catch {
            alert = Alert(message: "暂时无法保存这条记录。内容仍在这里，请稍后重试。")
            return false
        }

        let displayedDayKey = DayKey(containing: todayDate, in: todayTimeZone)
        if displayedDayKey == entry.dayKey {
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
        } else {
            entries = [entry]
        }
        todayDate = recordingContext.instant
        todayTimeZone = recordingContext.timeZone
        clearCaptureDraftInMemory()
        if canPersistCaptureDraft {
            do {
                try await captureDraftStore.clear()
            } catch {
                alert = Alert(message: "记录已保存，但暂时无法清理本地草稿。")
            }
        }
        route = .today
        showNotice("已保存到今天")

        await refreshToday(showError: false)
        return true
    }

    func refreshToday(showError: Bool = true) async {
        let date = now()
        let timeZone = currentTimeZone()
        let dayKey = DayKey(containing: date, in: timeZone)

        isLoadingToday = true
        defer { isLoadingToday = false }

        do {
            entries = try await workspace.entries(for: dayKey, userID: userID)
            todayDate = date
            todayTimeZone = timeZone
        } catch {
            if showError {
                alert = Alert(message: "暂时无法读取今天的记录，请稍后重试。")
            }
        }
    }

    func flushCaptureDraft() async {
        guard !isRestoringDraft, canPersistCaptureDraft else {
            return
        }

        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        let snapshot = captureDraftSnapshot
        draftPersistenceTask?.cancel()
        _ = await persistCaptureDraft(snapshot, generation: generation)
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.notice = nil
        }
    }

    private func restoreCaptureDraft() async -> Bool {
        var shouldSchedulePersistence = true
        defer {
            isRestoringDraft = false
            if shouldSchedulePersistence {
                scheduleDraftPersistence()
            }
        }

        let snapshot: CaptureDraftSnapshot
        do {
            guard let loadedSnapshot = try await captureDraftStore.load() else {
                return true
            }
            snapshot = loadedSnapshot
        } catch {
            shouldSchedulePersistence = false
            canPersistCaptureDraft = false
            isCaptureDraftAvailable = false
            alert = Alert(message: "上次未保存的草稿暂时无法读取。为避免覆盖原内容，当前记录已暂停，请重新打开 App 后再试。")
            return false
        }

        do {
            if try await workspace.hasCommittedDraft(id: snapshot.id, userID: userID) {
                do {
                    try await captureDraftStore.clear()
                } catch {
                    alert = Alert(message: "记录已保存，但暂时无法清理本地草稿。")
                }
                return true
            }
        } catch {
            alert = Alert(message: "暂时无法确认上次草稿是否已保存，请先核对今天的记录。")
        }

        suppressDraftPersistence = true
        captureDraftID = snapshot.id
        draftText = snapshot.text
        draftPhotos = snapshot.photos.map(Self.draftPhoto(from:))
        suppressDraftPersistence = false
        return true
    }

    private func scheduleDraftPersistence() {
        guard canPersistCaptureDraft,
              !suppressDraftPersistence,
              !isRestoringDraft else {
            return
        }

        let snapshot = captureDraftSnapshot
        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  self?.draftPersistenceGeneration == generation else {
                return
            }
            _ = await self?.persistCaptureDraft(snapshot, generation: generation)
        }
    }

    private func persistCaptureDraft(
        _ snapshot: CaptureDraftSnapshot,
        generation: Int
    ) async -> Bool {
        guard canPersistCaptureDraft,
              !Task.isCancelled,
              generation == draftPersistenceGeneration else {
            return false
        }
        do {
            if snapshot.text.isEmpty && snapshot.photos.isEmpty {
                try await captureDraftStore.clear()
            } else {
                try await captureDraftStore.save(snapshot)
            }
            guard !Task.isCancelled, generation == draftPersistenceGeneration else {
                return false
            }
            reportedDraftPersistenceError = false
            return true
        } catch {
            guard !reportedDraftPersistenceError else {
                return false
            }
            reportedDraftPersistenceError = true
            alert = Alert(message: "草稿暂时无法写入本地，请尽快保存记录。")
            return false
        }
    }

    private var captureDraftSnapshot: CaptureDraftSnapshot {
        CaptureDraftSnapshot(
            id: captureDraftID,
            text: draftText,
            photos: draftPhotos.map(Self.snapshot(from:))
        )
    }

    private func clearCaptureDraftInMemory() {
        draftPersistenceGeneration += 1
        draftPersistenceTask?.cancel()
        suppressDraftPersistence = true
        draftText = ""
        draftPhotos = []
        captureDraftID = UUID()
        suppressDraftPersistence = false
    }

    private func reconcilePhotoStorage() async {
        do {
            var referencedIDs = try await workspace.allPhotoIDs()
            for draftPhoto in draftPhotos {
                if case let .ready(photo) = draftPhoto.state {
                    referencedIDs.insert(photo.id)
                }
            }
            try await photoLibrary.removeUnreferencedPhotos(
                keeping: referencedIDs,
                olderThan: Date().addingTimeInterval(-3_600)
            )
        } catch {
            // 媒体清理失败不应阻断记录与读取，后续启动会再次尝试。
        }
    }

    private func persistDraftAfterRemovingPhoto(_ removedPhoto: DraftPhoto) {
        draftPersistenceGeneration += 1
        let generation = draftPersistenceGeneration
        let snapshot = captureDraftSnapshot
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didPersist = await self.persistCaptureDraft(snapshot, generation: generation)
            guard didPersist,
                  !Task.isCancelled,
                  self.draftPersistenceGeneration == generation,
                  case let .ready(photo) = removedPhoto.state else {
                return
            }

            do {
                let referencedPhotoIDs = try await self.workspace.allPhotoIDs()
                guard !Task.isCancelled,
                      self.draftPersistenceGeneration == generation,
                      !referencedPhotoIDs.contains(photo.id) else {
                    return
                }
                try await self.photoLibrary.removePhoto(photo)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.alert = Alert(message: "暂时无法清理这张照片，请稍后重试。")
            }
        }
    }

    private static func snapshot(from draftPhoto: DraftPhoto) -> CaptureDraftPhotoSnapshot {
        let status: CaptureDraftPhotoSnapshot.Status
        let mediaMetadata: CaptureDraftPhotoSnapshot.MediaMetadata?

        switch draftPhoto.state {
        case .importing:
            status = .importing
            mediaMetadata = nil
        case .failed:
            status = .failed
            mediaMetadata = nil
        case let .ready(photo):
            status = .ready
            mediaMetadata = CaptureDraftPhotoSnapshot.MediaMetadata(
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        }

        return CaptureDraftPhotoSnapshot(
            id: draftPhoto.id,
            status: status,
            annotationText: draftPhoto.annotationText,
            mediaMetadata: mediaMetadata
        )
    }

    private static func draftPhoto(from snapshot: CaptureDraftPhotoSnapshot) -> DraftPhoto {
        let state: DraftPhoto.State
        if snapshot.status == .ready, let metadata = snapshot.mediaMetadata {
            state = .ready(
                ImportedPhoto(
                    id: snapshot.id,
                    contentTypeIdentifier: metadata.contentTypeIdentifier,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    byteCount: metadata.byteCount,
                    originalRelativePath: metadata.originalRelativePath,
                    thumbnailRelativePath: metadata.thumbnailRelativePath
                )
            )
        } else {
            state = .failed
        }

        return DraftPhoto(
            id: snapshot.id,
            state: state,
            annotationText: snapshot.annotationText
        )
    }
}
