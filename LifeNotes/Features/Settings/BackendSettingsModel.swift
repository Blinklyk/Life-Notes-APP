import Combine
import Foundation

@MainActor
final class BackendSettingsModel: ObservableObject {
    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let message: String

        static func == (lhs: Alert, rhs: Alert) -> Bool {
            lhs.id == rhs.id && lhs.message == rhs.message
        }
    }

    @Published var isEnabled = false {
        didSet { formValueDidChange() }
    }
    @Published var baseURLText = "" {
        didSet { formValueDidChange() }
    }
    @Published var bearerTokenReplacement = "" {
        didSet { formValueDidChange() }
    }
    @Published private(set) var hasStoredBearerToken = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isCheckingHealth = false
    @Published private(set) var statusMessage: String?
    @Published var alert: Alert?

    private let configurationStore: any AIBackendConfigurationStore
    private let healthChecker: any AIBackendHealthChecking
    private var loadGeneration = 0
    private var healthGeneration = 0
    private var suppressesFormInvalidation = false

    init(
        configurationStore: any AIBackendConfigurationStore,
        healthChecker: any AIBackendHealthChecking
    ) {
        self.configurationStore = configurationStore
        self.healthChecker = healthChecker
    }

    var isBusy: Bool {
        isLoading || isSaving || isCheckingHealth
    }

    var canSave: Bool {
        !isBusy
            && !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isEnabled
                || hasStoredBearerToken
                || !bearerTokenReplacement.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        statusMessage = nil
        alert = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let snapshot = try await configurationStore.loadSettings()
            guard loadGeneration == generation else {
                return
            }
            apply(snapshot)
        } catch {
            guard loadGeneration == generation else {
                return
            }
            alert = Alert(message: Self.message(for: error, fallback: "暂时无法读取后端设置。"))
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave else {
            return false
        }
        isSaving = true
        statusMessage = nil
        alert = nil
        defer { isSaving = false }

        let replacement = bearerTokenReplacement.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let update = AIBackendConfigurationUpdate(
            isEnabled: isEnabled,
            baseURLText: baseURLText,
            bearerTokenReplacement: replacement.isEmpty ? nil : replacement
        )
        do {
            try await configurationStore.save(update)
            let snapshot = try await configurationStore.loadSettings()
            apply(snapshot, fallbackBaseURLText: baseURLText)
            statusMessage = "后端设置已安全保存。"
            return true
        } catch {
            alert = Alert(message: Self.message(for: error, fallback: "暂时无法保存后端设置。"))
            return false
        }
    }

    func checkHealth() async {
        guard !isBusy else {
            return
        }
        healthGeneration += 1
        let generation = healthGeneration
        let testedURLText = baseURLText
        isCheckingHealth = true
        statusMessage = nil
        alert = nil
        defer {
            if healthGeneration == generation {
                isCheckingHealth = false
            }
        }

        do {
            let baseURL = try AIBackendURLPolicy.validatedBaseURL(testedURLText)
            try await healthChecker.check(baseURL: baseURL)
            guard healthGeneration == generation,
                  baseURLText == testedURLText else {
                return
            }
            statusMessage = "后端连接正常。"
        } catch is CancellationError {
            return
        } catch {
            guard healthGeneration == generation,
                  baseURLText == testedURLText else {
                return
            }
            alert = Alert(message: Self.message(for: error, fallback: "无法连接后端。"))
        }
    }

    func clear() async {
        guard !isBusy else {
            return
        }
        isSaving = true
        statusMessage = nil
        alert = nil
        defer { isSaving = false }

        do {
            try await configurationStore.clear()
            apply(.empty)
            statusMessage = "后端设置已清除，日记将使用本地生成。"
        } catch {
            alert = Alert(message: Self.message(for: error, fallback: "暂时无法清除后端设置。"))
        }
    }

    func clearSensitiveDraft() {
        bearerTokenReplacement = ""
    }

    private func apply(
        _ snapshot: AIBackendSettingsSnapshot,
        fallbackBaseURLText: String? = nil
    ) {
        suppressesFormInvalidation = true
        defer { suppressesFormInvalidation = false }
        isEnabled = snapshot.isEnabled
        baseURLText = snapshot.baseURL?.absoluteString
            ?? fallbackBaseURLText
            ?? Self.defaultBaseURLText
        hasStoredBearerToken = snapshot.hasBearerToken
        bearerTokenReplacement = ""
    }

    private func formValueDidChange() {
        guard !suppressesFormInvalidation else {
            return
        }
        statusMessage = nil
        alert = nil
    }

    private static var defaultBaseURLText: String {
#if DEBUG
        AIBackendURLPolicy.debugDefaultBaseURLText
#else
        ""
#endif
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}
