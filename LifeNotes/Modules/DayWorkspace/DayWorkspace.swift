import Foundation

enum DayWorkspaceError: LocalizedError, Equatable {
    case voiceAttachmentNotFound
    case entryNotFound
    case entryRevisionConflict(expected: Int, actual: Int)
    case invalidPhotoAnnotationSet
    case invalidVoiceTranscriptSet
    case entryMutationUnavailable
    case entrySearchUnavailable
    case invalidDayRange
    case calendarSummariesUnavailable

    var errorDescription: String? {
        switch self {
        case .voiceAttachmentNotFound:
            return "找不到要更新的语音记录。"
        case .entryNotFound:
            return "找不到要修改的随心记录。"
        case .entryRevisionConflict:
            return "这条随心记录已在其他位置更新，请刷新后重试。"
        case .invalidPhotoAnnotationSet:
            return "图片批注与当前记录不一致，请刷新后重试。"
        case .invalidVoiceTranscriptSet:
            return "语音转写与当前记录不一致，请刷新后重试。"
        case .entryMutationUnavailable:
            return "当前数据源暂不支持修改随心记录。"
        case .entrySearchUnavailable:
            return "当前数据源暂不支持搜索随心记录。"
        case .invalidDayRange:
            return "日历查询的起始日期不能晚于结束日期。"
        case .calendarSummariesUnavailable:
            return "当前数据源暂不支持日历汇总。"
        }
    }
}

protocol DayWorkspace: Sendable {
    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry]

    func updateEntry(
        id: UUID,
        userID: UUID,
        edit: EntryEdit,
        updatedAt: Date
    ) async throws -> Entry

    func deleteEntry(
        id: UUID,
        userID: UUID,
        expectedRevision: Int,
        deletedAt: Date
    ) async throws -> Entry

    func searchEntries(matching query: String, userID: UUID) async throws -> [Entry]

    func daySummaries(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) async throws -> [CalendarDaySummary]

    func dayDetail(for day: DayKey, userID: UUID) async throws -> DayDetail

    func dayState(for day: DayKey, userID: UUID) async throws -> DayState

    func setFeeling(
        _ feeling: DailyFeeling?,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool

    func photoIDs(userID: UUID) async throws -> Set<UUID>

    func allPhotoIDs() async throws -> Set<UUID>

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID>

    func allRetainedVoiceIDs() async throws -> Set<UUID>

    func updateVoiceTranscript(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) async throws -> VoiceAttachment
}

extension DayWorkspace {
    func updateEntry(
        id: UUID,
        userID: UUID,
        edit: EntryEdit,
        updatedAt: Date
    ) async throws -> Entry {
        throw DayWorkspaceError.entryMutationUnavailable
    }

    func deleteEntry(
        id: UUID,
        userID: UUID,
        expectedRevision: Int,
        deletedAt: Date
    ) async throws -> Entry {
        throw DayWorkspaceError.entryMutationUnavailable
    }

    func searchEntries(matching query: String, userID: UUID) async throws -> [Entry] {
        throw DayWorkspaceError.entrySearchUnavailable
    }

    func daySummaries(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) async throws -> [CalendarDaySummary] {
        throw DayWorkspaceError.calendarSummariesUnavailable
    }

    func dayDetail(for day: DayKey, userID: UUID) async throws -> DayDetail {
        async let loadedEntries = entries(for: day, userID: userID)
        async let loadedState = dayState(for: day, userID: userID)
        let (entries, state) = try await (loadedEntries, loadedState)
        return DayDetail(dayKey: day, entries: entries, state: state)
    }
}
