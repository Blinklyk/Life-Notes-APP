import Combine
import Foundation

@MainActor
final class JournalModel: ObservableObject {
    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let message: String

        static func == (lhs: Alert, rhs: Alert) -> Bool {
            lhs.id == rhs.id && lhs.message == rhs.message
        }
    }

    @Published private(set) var selectedDay: DayKey?
    @Published private(set) var journalDay: JournalDay?
    @Published private(set) var sourceEntries: [Entry] = []
    @Published private(set) var sourceFingerprint: JournalSourceFingerprint?
    @Published private(set) var hasNewSourceMaterial = false
    @Published private(set) var previewedVersion: JournalVersion?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isSaving = false
    @Published var writingStyle: WritingStyle {
        didSet {
            if writingStyle != oldValue {
                onWritingStyleChange(writingStyle)
            }
        }
    }
    @Published var alert: Alert?

    private let dayWorkspace: any DayWorkspace
    private let journalWorkspace: any JournalWorkspace
    private let generator: any JournalGenerator
    private let userID: UUID
    private let now: @Sendable () -> Date
    private let onWritingStyleChange: (WritingStyle) -> Void

    private var loadGeneration = 0
    private var operationGeneration = 0
    private var persistedAppendGenerations: [DayKey: Int] = [:]

    init(
        dayWorkspace: any DayWorkspace,
        journalWorkspace: any JournalWorkspace,
        generator: any JournalGenerator,
        userID: UUID,
        writingStyle: WritingStyle = .natural,
        now: @escaping @Sendable () -> Date = { Date() },
        onWritingStyleChange: @escaping (WritingStyle) -> Void = { _ in }
    ) {
        self.dayWorkspace = dayWorkspace
        self.journalWorkspace = journalWorkspace
        self.generator = generator
        self.userID = userID
        self.now = now
        self.onWritingStyleChange = onWritingStyleChange
        self.writingStyle = writingStyle
    }

    var currentVersion: JournalVersion? {
        journalDay?.currentVersion
    }

    var historyVersions: [JournalVersion] {
        journalDay?.historyVersions ?? []
    }

    var isBusy: Bool {
        isLoading || isGenerating || isSaving
    }

    var canGenerate: Bool {
        selectedDay != nil && !isBusy && Self.hasUnderstandableText(in: sourceEntries)
    }

    func load(day: DayKey, showError: Bool = true) async {
        let changesDay = selectedDay != day
        loadGeneration += 1
        if changesDay {
            operationGeneration += 1
        }
        let generation = loadGeneration
        let persistedAppendGeneration = persistedAppendGeneration(for: day)

        selectedDay = day
        isLoading = true
        alert = nil

        if changesDay {
            previewedVersion = nil
            isGenerating = false
            isSaving = false
            journalDay = nil
            sourceEntries = []
            sourceFingerprint = nil
            hasNewSourceMaterial = false
        }

        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            async let loadedEntries = dayWorkspace.entries(for: day, userID: userID)
            async let loadedJournal = journalWorkspace.journal(for: day, userID: userID)
            let (entries, journal) = try await (loadedEntries, loadedJournal)
            let fingerprint = try JournalSourceFingerprint.make(entries: entries)

            guard loadGeneration == generation, selectedDay == day else {
                return
            }
            guard entries.allSatisfy({ $0.dayKey == day && $0.userID == userID }) else {
                throw JournalModelError.invalidLoadedScope
            }
            if let journal, journal.dayKey != day {
                throw JournalModelError.invalidLoadedScope
            }

            sourceEntries = JournalSourceOrdering.entries(entries)
            sourceFingerprint = fingerprint
            if self.persistedAppendGeneration(for: day) == persistedAppendGeneration {
                journalDay = journal
            }
            updateNewSourceMaterialFlag()
        } catch {
            guard loadGeneration == generation, selectedDay == day else {
                return
            }
            if showError {
                alert = Alert(message: "暂时无法读取这一天的随心日记，请稍后重试。")
            }
        }
    }

    @discardableResult
    func generate() async -> Bool {
        await generateVersion(requiresCurrentVersion: false)
    }

    @discardableResult
    func regenerate() async -> Bool {
        await generateVersion(requiresCurrentVersion: true)
    }

    @discardableResult
    func saveEdits(title: String, blocks: [JournalBlock]) async -> Bool {
        guard Self.hasMeaningfulJournalContent(title: title, blocks: blocks) else {
            alert = Alert(message: "请先写下一点日记内容。")
            return false
        }
        guard let context = beginOperation(.saving) else {
            return false
        }
        defer { finishOperation(context) }

        let baseVersion = journalDay?.currentVersion
        let fingerprint: JournalSourceFingerprint
        let sourceEntryCount: Int
        if let baseVersion {
            fingerprint = baseVersion.sourceFingerprint
            sourceEntryCount = baseVersion.sourceEntryCount
        } else {
            guard let currentFingerprint = sourceFingerprint else {
                alert = Alert(message: "请先读取这一天的记录，再保存日记。")
                return false
            }
            fingerprint = currentFingerprint
            sourceEntryCount = sourceEntries.count
        }

        let draft = NewJournalVersion(
            title: title,
            blocks: blocks,
            origin: .edited,
            sourceFingerprint: fingerprint,
            sourceEntryCount: sourceEntryCount,
            baseVersionID: baseVersion?.id,
            generatorIdentifier: baseVersion?.generatorIdentifier,
            createdAt: now()
        )
        return await append(
            draft,
            context: context,
            failureMessage: "暂时无法保存日记修改，请稍后重试。"
        )
    }

    func preview(_ version: JournalVersion) {
        guard let canonicalVersion = journalDay?.allVersions.first(where: { $0.id == version.id }) else {
            return
        }
        previewedVersion = canonicalVersion
    }

    func previewVersion(id: UUID) {
        guard let version = journalDay?.allVersions.first(where: { $0.id == id }) else {
            return
        }
        previewedVersion = version
    }

    func dismissPreview() {
        previewedVersion = nil
    }

    @discardableResult
    func restorePreviewedVersion() async -> Bool {
        guard let version = previewedVersion else {
            return false
        }
        guard let context = beginOperation(.saving) else {
            return false
        }
        defer { finishOperation(context) }

        let draft = NewJournalVersion(
            title: version.title,
            blocks: version.blocks,
            origin: .restored,
            sourceFingerprint: version.sourceFingerprint,
            sourceEntryCount: version.sourceEntryCount,
            baseVersionID: version.id,
            generatorIdentifier: version.generatorIdentifier,
            createdAt: now()
        )
        return await append(
            draft,
            context: context,
            failureMessage: "暂时无法恢复这个历史版本，请稍后重试。"
        )
    }

    private func generateVersion(requiresCurrentVersion: Bool) async -> Bool {
        if requiresCurrentVersion, journalDay == nil {
            alert = Alert(message: "当前还没有可重新生成的随心日记。")
            return false
        }
        guard canGenerate else {
            if !isBusy {
                alert = Alert(message: "这一天还没有可用于生成日记的文字、图片批注或语音转写。")
            }
            return false
        }
        guard let context = beginOperation(.generating),
              let expectedFingerprint = sourceFingerprint else {
            return false
        }
        defer { finishOperation(context) }

        do {
            let generated = try await generator.generate(
                JournalGenerationRequest(
                    dayKey: context.day,
                    entries: sourceEntries,
                    style: writingStyle
                )
            )
            guard isCurrentGenerationInput(context) else {
                return false
            }
            guard generated.sourceFingerprint == expectedFingerprint,
                  generated.sourceEntryCount == sourceEntries.count,
                  generator.acceptsGeneratorIdentifier(generated.generatorIdentifier),
                  Self.hasMeaningfulJournalContent(
                      title: generated.title,
                      blocks: generated.blocks
                  ),
                  Self.generatedPhotosBelongToSource(
                      generated.blocks,
                      sourceEntries: sourceEntries
                  ) else {
                throw JournalModelError.invalidGeneratedDraft
            }

            let draft = NewJournalVersion(
                title: generated.title,
                blocks: generated.blocks,
                origin: .generated,
                sourceFingerprint: generated.sourceFingerprint,
                sourceEntryCount: generated.sourceEntryCount,
                baseVersionID: journalDay?.currentVersion.id,
                generatorIdentifier: generated.generatorIdentifier,
                createdAt: now()
            )
            let didAppend = await append(
                draft,
                context: context,
                failureMessage: "暂时无法生成并保存随心日记，请稍后重试。"
            )
            if didAppend,
               isCurrentOperation(context),
               let notice = generated.notice {
                alert = Alert(message: notice)
            }
            return didAppend
        } catch {
            guard isCurrentGenerationInput(context) else {
                return false
            }
            if let remoteError = error as? RemoteJournalGenerationError {
                alert = Alert(message: remoteError.localizedDescription)
            } else if let configurationError = error as? AIBackendConfigurationError {
                alert = Alert(message: configurationError.localizedDescription)
            } else {
                alert = Alert(message: "暂时无法生成并保存随心日记，请稍后重试。")
            }
            return false
        }
    }

    private func append(
        _ draft: NewJournalVersion,
        context: OperationContext,
        failureMessage: String
    ) async -> Bool {
        do {
            let updatedJournal = try await journalWorkspace.append(
                draft,
                for: context.day,
                userID: userID
            )
            guard updatedJournal.dayKey == context.day,
                  updatedJournal.currentVersion.id == draft.id else {
                throw JournalModelError.invalidLoadedScope
            }
            let persistedGeneration = registerPersistedAppend(for: context.day)

            guard isCurrentOperation(context) else {
                if selectedDay == context.day {
                    await reconcilePersistedAppend(
                        updatedJournal,
                        draftID: draft.id,
                        day: context.day,
                        persistedGeneration: persistedGeneration
                    )
                }
                return true
            }

            journalDay = updatedJournal
            previewedVersion = nil
            updateNewSourceMaterialFlag()
            return true
        } catch {
            guard isCurrentOperation(context) else {
                return false
            }
            alert = Alert(message: failureMessage)
            return false
        }
    }

    private func beginOperation(_ kind: OperationKind) -> OperationContext? {
        guard !isBusy, let day = selectedDay else {
            return nil
        }
        operationGeneration += 1
        let context = OperationContext(
            day: day,
            loadGeneration: loadGeneration,
            operationGeneration: operationGeneration,
            kind: kind
        )
        alert = nil
        switch kind {
        case .generating:
            isGenerating = true
        case .saving:
            isSaving = true
        }
        return context
    }

    private func finishOperation(_ context: OperationContext) {
        guard operationGeneration == context.operationGeneration else {
            return
        }
        switch context.kind {
        case .generating:
            isGenerating = false
        case .saving:
            isSaving = false
        }
    }

    private func isCurrentOperation(_ context: OperationContext) -> Bool {
        selectedDay == context.day
            && operationGeneration == context.operationGeneration
    }

    private func isCurrentGenerationInput(_ context: OperationContext) -> Bool {
        isCurrentOperation(context) && loadGeneration == context.loadGeneration
    }

    private func persistedAppendGeneration(for day: DayKey) -> Int {
        persistedAppendGenerations[day, default: 0]
    }

    @discardableResult
    private func registerPersistedAppend(for day: DayKey) -> Int {
        let generation = persistedAppendGeneration(for: day) + 1
        persistedAppendGenerations[day] = generation
        return generation
    }

    private func reconcilePersistedAppend(
        _ updatedJournal: JournalDay,
        draftID: UUID,
        day: DayKey,
        persistedGeneration: Int
    ) async {
        await load(day: day, showError: false)
        guard selectedDay == day else {
            return
        }
        if journalDay?.allVersions.contains(where: { $0.id == draftID }) == true {
            return
        }
        guard persistedAppendGeneration(for: day) == persistedGeneration else {
            return
        }

        journalDay = updatedJournal
        previewedVersion = nil
        updateNewSourceMaterialFlag()
    }

    private func updateNewSourceMaterialFlag() {
        guard let sourceFingerprint, let currentVersion = journalDay?.currentVersion else {
            hasNewSourceMaterial = false
            return
        }
        hasNewSourceMaterial = currentVersion.sourceFingerprint != sourceFingerprint
    }

    private static func hasUnderstandableText(in entries: [Entry]) -> Bool {
        entries.contains { entry in
            isNonempty(entry.text)
                || entry.photos.contains { isNonempty($0.annotationText) }
                || entry.voices.contains { isNonempty($0.transcriptText) }
        }
    }

    private static func hasMeaningfulJournalContent(
        title: String,
        blocks: [JournalBlock]
    ) -> Bool {
        if isNonempty(title) {
            return true
        }
        return blocks.contains { block in
            switch block.content {
            case let .text(text):
                return isNonempty(text)
            case .photo:
                return true
            }
        }
    }

    private static func generatedPhotosBelongToSource(
        _ blocks: [JournalBlock],
        sourceEntries: [Entry]
    ) -> Bool {
        var sourcePhotos: [UUID: PhotoAttachment] = [:]
        for photo in sourceEntries.flatMap(\.photos) {
            if let existing = sourcePhotos[photo.id], existing != photo {
                return false
            }
            sourcePhotos[photo.id] = photo
        }

        var generatedPhotoIDs: Set<UUID> = []
        for photo in blocks.compactMap(\.photo) {
            guard
                generatedPhotoIDs.insert(photo.id).inserted,
                sourcePhotos[photo.id] == photo
            else {
                return false
            }
        }
        return true
    }

    private static func isNonempty(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct OperationContext {
    let day: DayKey
    let loadGeneration: Int
    let operationGeneration: Int
    let kind: OperationKind
}

private enum OperationKind {
    case generating
    case saving
}

private enum JournalModelError: Error {
    case invalidLoadedScope
    case invalidGeneratedDraft
}
