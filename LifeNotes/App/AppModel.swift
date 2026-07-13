import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Route: Equatable {
        case capture
        case today
    }

    struct Alert: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published var draftText = ""
    @Published private(set) var route: Route = .capture
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var todayDate: Date
    @Published private(set) var todayTimeZone: TimeZone
    @Published private(set) var isLoadingToday = false
    @Published private(set) var isSaving = false
    @Published private(set) var notice: String?
    @Published var alert: Alert?

    private let workspace: any DayWorkspace
    private let userID: UUID
    private let now: @Sendable () -> Date
    private let currentTimeZone: @Sendable () -> TimeZone
    private var noticeTask: Task<Void, Never>?

    init(
        workspace: any DayWorkspace,
        userID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.workspace = workspace
        self.userID = userID
        self.now = now
        self.currentTimeZone = currentTimeZone

        let initialDate = now()
        todayDate = initialDate
        todayTimeZone = currentTimeZone()

        Task { [weak self] in
            await self?.refreshToday(showError: false)
        }
    }

    var canSaveDraft: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
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
        guard !isSaving else {
            return false
        }

        let draft: NewTextEntry
        do {
            draft = try NewTextEntry(draftText)
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

        do {
            let entry = try await workspace.createText(
                draft,
                userID: userID,
                context: recordingContext
            )
            let savedEntries = try await workspace.entries(for: entry.dayKey, userID: userID)

            entries = savedEntries
            todayDate = recordingContext.instant
            todayTimeZone = recordingContext.timeZone
            draftText = ""
            route = .today
            showNotice("已保存到今天")
            return true
        } catch {
            alert = Alert(message: "暂时无法保存这条记录。内容仍在这里，请稍后重试。")
            return false
        }
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
}
