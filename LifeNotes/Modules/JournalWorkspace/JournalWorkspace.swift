import Foundation

protocol JournalWorkspace: Sendable {
    func journal(for day: DayKey, userID: UUID) async throws -> JournalDay?

    func append(
        _ draft: NewJournalVersion,
        for day: DayKey,
        userID: UUID
    ) async throws -> JournalDay
}

enum JournalPersistenceError: LocalizedError, Equatable {
    case invalidJournalScope(String)
    case orphanedVersions(String)
    case invalidVersionScope(UUID)
    case invalidCurrentVersion(UUID)
    case invalidVersionNumber(Int)
    case invalidVersionOrigin(String)
    case invalidSourceFingerprint
    case invalidSourceEntryCount(Int)
    case invalidBlocksData
    case missingBaseVersion(UUID)
    case conflictingVersionID(UUID)

    var errorDescription: String? {
        switch self {
        case let .invalidJournalScope(scopeKey):
            return "本地日记包含无效的用户或日期范围：\(scopeKey)。"
        case let .orphanedVersions(scopeKey):
            return "本地日记版本缺少主记录：\(scopeKey)。"
        case let .invalidVersionScope(versionID):
            return "本地日记版本属于错误的用户、日期或日记：\(versionID)。"
        case let .invalidCurrentVersion(versionID):
            return "本地日记当前版本引用无效：\(versionID)。"
        case let .invalidVersionNumber(number):
            return "本地日记包含无效的版本号：\(number)。"
        case let .invalidVersionOrigin(origin):
            return "本地日记包含无效的版本来源：\(origin)。"
        case .invalidSourceFingerprint:
            return "本地日记的素材指纹无效。"
        case let .invalidSourceEntryCount(count):
            return "本地日记的素材数量无效：\(count)。"
        case .invalidBlocksData:
            return "本地日记的图文内容已损坏。"
        case let .missingBaseVersion(versionID):
            return "本地日记找不到引用的基础版本：\(versionID)。"
        case let .conflictingVersionID(versionID):
            return "本地日记版本标识与已有内容冲突：\(versionID)。"
        }
    }
}
