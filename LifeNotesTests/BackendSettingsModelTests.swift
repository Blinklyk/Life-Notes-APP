import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class BackendSettingsModelTests: XCTestCase {
    func testLoadPublishesOnlyTokenPresenceAndClearsReplacementDraft() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "https://notes.example.com/api")!,
                hasBearerToken: true
            )
        )
        let model = makeModel(store: store)
        model.bearerTokenReplacement = "must-not-survive-load"

        await model.load()
        let configurationLoadCount = await store.configurationLoadCallCount()

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.baseURLText, "https://notes.example.com/api")
        XCTAssertTrue(model.hasStoredBearerToken)
        XCTAssertEqual(model.bearerTokenReplacement, "")
        XCTAssertEqual(configurationLoadCount, 0)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.alert)
    }

    func testSavingEmptyReplacementPreservesStoredToken() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "https://notes.example.com")!,
                hasBearerToken: true
            )
        )
        let model = makeModel(store: store)
        await model.load()
        model.baseURLText = "https://new.example.com/root"
        model.bearerTokenReplacement = "  \n  "

        let didSave = await model.save()
        let updates = await store.capturedUpdates()
        let snapshot = await store.currentSnapshot()

        XCTAssertTrue(didSave)
        XCTAssertEqual(
            updates,
            [
                AIBackendConfigurationUpdate(
                    isEnabled: true,
                    baseURLText: "https://new.example.com/root",
                    bearerTokenReplacement: nil
                )
            ]
        )
        XCTAssertTrue(snapshot.hasBearerToken)
        XCTAssertTrue(model.hasStoredBearerToken)
        XCTAssertEqual(model.bearerTokenReplacement, "")
        XCTAssertEqual(model.statusMessage, "后端设置已安全保存。")
    }

    func testSavingNewTokenSendsTrimmedReplacementThenClearsDraft() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: false,
                baseURL: URL(string: "https://notes.example.com")!,
                hasBearerToken: false
            )
        )
        let model = makeModel(store: store)
        await model.load()
        model.isEnabled = true
        model.bearerTokenReplacement = "  0123456789abcdef-new-token  "

        let didSave = await model.save()
        let update = await store.capturedUpdates().last

        XCTAssertTrue(didSave)
        XCTAssertEqual(update?.bearerTokenReplacement, "0123456789abcdef-new-token")
        XCTAssertTrue(model.hasStoredBearerToken)
        XCTAssertEqual(model.bearerTokenReplacement, "")
    }

    func testHealthCheckPublishesSuccessAndLocalizedFailure() async {
        let healthChecker = BackendSettingsTestHealthChecker(
            responses: [.success, .status(503)]
        )
        let model = makeModel(healthChecker: healthChecker)
        model.baseURLText = "https://notes.example.com/api/"

        await model.checkHealth()

        XCTAssertEqual(model.statusMessage, "后端连接正常。")
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.isCheckingHealth)

        await model.checkHealth()

        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.alert?.message, "后端健康检查返回了 HTTP 503。")
        XCTAssertFalse(model.isCheckingHealth)
        let calls = await healthChecker.capturedURLs()
        XCTAssertEqual(
            calls.map(\.absoluteString),
            ["https://notes.example.com/api", "https://notes.example.com/api"]
        )
    }

    func testClearRemovesStoreAndAllSensitiveModelState() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "https://notes.example.com")!,
                hasBearerToken: true
            )
        )
        let model = makeModel(store: store)
        await model.load()
        model.bearerTokenReplacement = "unsaved-secret"

        await model.clear()
        let clearCallCount = await store.clearCallCount()
        let clearedSnapshot = await store.currentSnapshot()

        XCTAssertEqual(clearCallCount, 1)
        XCTAssertEqual(clearedSnapshot, .empty)
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.hasStoredBearerToken)
        XCTAssertEqual(model.bearerTokenReplacement, "")
        XCTAssertEqual(
            model.baseURLText,
            AIBackendURLPolicy.allowsInsecureLocalHTTP
                ? AIBackendURLPolicy.debugDefaultBaseURLText
                : ""
        )
        XCTAssertEqual(
            model.statusMessage,
            "后端设置已清除，日记将使用本地生成。"
        )
        XCTAssertFalse(model.isSaving)
    }

    func testSaveGuardsIncompleteFormWithoutCallingStore() async {
        let store = BackendSettingsTestStore(snapshot: .empty)
        let model = makeModel(store: store)
        model.isEnabled = true
        model.baseURLText = "https://notes.example.com"
        model.bearerTokenReplacement = ""

        XCTAssertFalse(model.canSave)
        let missingTokenDidSave = await model.save()
        XCTAssertFalse(missingTokenDidSave)

        model.isEnabled = false
        model.baseURLText = "  \n "
        XCTAssertFalse(model.canSave)
        let missingURLDidSave = await model.save()
        let updates = await store.capturedUpdates()
        XCTAssertFalse(missingURLDidSave)
        XCTAssertTrue(updates.isEmpty)
        XCTAssertNil(model.alert)
    }

    func testSaveSurfacesValidationAndStoreErrorsWithoutClearingDraft() async {
        let validationStore = BackendSettingsTestStore(
            snapshot: .empty,
            saveFailure: .configuration(.invalidURL)
        )
        let validationModel = makeModel(store: validationStore)
        validationModel.isEnabled = true
        validationModel.baseURLText = "not-a-url"
        validationModel.bearerTokenReplacement = "0123456789abcdef-token"

        let validationDidSave = await validationModel.save()
        XCTAssertFalse(validationDidSave)
        XCTAssertEqual(validationModel.alert?.message, "请输入完整的后端地址。")
        XCTAssertEqual(
            validationModel.bearerTokenReplacement,
            "0123456789abcdef-token"
        )
        XCTAssertNil(validationModel.statusMessage)

        let failingStore = BackendSettingsTestStore(
            snapshot: .empty,
            saveFailure: .generic
        )
        let failingModel = makeModel(store: failingStore)
        failingModel.isEnabled = true
        failingModel.baseURLText = "https://notes.example.com"
        failingModel.bearerTokenReplacement = "0123456789abcdef-token"

        let failingStoreDidSave = await failingModel.save()
        XCTAssertFalse(failingStoreDidSave)
        XCTAssertEqual(failingModel.alert?.message, "暂时无法保存后端设置。")
        XCTAssertEqual(failingModel.bearerTokenReplacement, "0123456789abcdef-token")
        XCTAssertFalse(failingModel.isSaving)
    }

    func testClosingSettingsClearsOnlySensitiveReplacementDraft() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "https://notes.example.com")!,
                hasBearerToken: true
            )
        )
        let model = makeModel(store: store)
        await model.load()
        model.bearerTokenReplacement = "unsaved-secret"

        model.clearSensitiveDraft()
        let updates = await store.capturedUpdates()

        XCTAssertEqual(model.bearerTokenReplacement, "")
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.hasStoredBearerToken)
        XCTAssertEqual(model.baseURLText, "https://notes.example.com")
        XCTAssertTrue(updates.isEmpty)
    }

    func testLateHealthResultCannotOverwriteFormAfterURLChanges() async {
        for response in [
            BackendSettingsTestHealthChecker.Response.success,
            .status(503)
        ] {
            let gate = BackendSettingsTestGate()
            let healthChecker = BackendSettingsTestHealthChecker(
                responses: [response.waiting(on: gate)]
            )
            let model = makeModel(healthChecker: healthChecker)
            model.baseURLText = "https://old.example.com"

            let healthTask = Task { await model.checkHealth() }
            await waitUntil { await gate.hasWaiter() }
            XCTAssertTrue(model.isCheckingHealth)

            model.baseURLText = "https://new.example.com"
            await gate.open()
            await healthTask.value

            XCTAssertEqual(model.baseURLText, "https://new.example.com")
            XCTAssertNil(model.statusMessage)
            XCTAssertNil(model.alert)
            XCTAssertFalse(model.isCheckingHealth)
        }
    }

    func testEditingAnyFormFieldInvalidatesStaleSuccessState() async {
        let store = BackendSettingsTestStore(
            snapshot: AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "https://notes.example.com")!,
                hasBearerToken: true
            )
        )
        let healthChecker = BackendSettingsTestHealthChecker(responses: [.success])
        let model = makeModel(store: store, healthChecker: healthChecker)
        await model.load()

        await model.checkHealth()
        XCTAssertEqual(model.statusMessage, "后端连接正常。")
        model.baseURLText = "https://new.example.com"
        XCTAssertNil(model.statusMessage)

        let firstSaveSucceeded = await model.save()
        XCTAssertTrue(firstSaveSucceeded)
        XCTAssertEqual(model.statusMessage, "后端设置已安全保存。")
        model.isEnabled.toggle()
        XCTAssertNil(model.statusMessage)

        let secondSaveSucceeded = await model.save()
        XCTAssertTrue(secondSaveSucceeded)
        XCTAssertEqual(model.statusMessage, "后端设置已安全保存。")
        model.bearerTokenReplacement = "0123456789abcdef-replacement"
        XCTAssertNil(model.statusMessage)
    }

    private func makeModel(
        store: BackendSettingsTestStore = BackendSettingsTestStore(snapshot: .empty),
        healthChecker: BackendSettingsTestHealthChecker = BackendSettingsTestHealthChecker(
            responses: []
        )
    ) -> BackendSettingsModel {
        BackendSettingsModel(
            configurationStore: store,
            healthChecker: healthChecker
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("等待异步条件超时", file: file, line: line)
    }
}

private actor BackendSettingsTestStore: AIBackendConfigurationStore {
    enum SaveFailure: Sendable {
        case configuration(AIBackendConfigurationError)
        case generic
    }

    private var snapshot: AIBackendSettingsSnapshot
    private let saveFailure: SaveFailure?
    private var updates: [AIBackendConfigurationUpdate] = []
    private var clearCalls = 0
    private var configurationLoadCalls = 0

    init(
        snapshot: AIBackendSettingsSnapshot,
        saveFailure: SaveFailure? = nil
    ) {
        self.snapshot = snapshot
        self.saveFailure = saveFailure
    }

    func loadConfiguration() async throws -> AIBackendConfiguration? {
        configurationLoadCalls += 1
        guard let baseURL = snapshot.baseURL else {
            return nil
        }
        return AIBackendConfiguration(
            isEnabled: snapshot.isEnabled,
            baseURL: baseURL,
            bearerToken: snapshot.hasBearerToken ? "stored-but-never-exposed-token" : ""
        )
    }

    func loadSettings() async throws -> AIBackendSettingsSnapshot {
        snapshot
    }

    func save(_ update: AIBackendConfigurationUpdate) async throws {
        updates.append(update)
        switch saveFailure {
        case let .configuration(error):
            throw error
        case .generic:
            throw BackendSettingsModelTestError.storeFailure
        case nil:
            break
        }

        let hasToken = snapshot.hasBearerToken || update.bearerTokenReplacement != nil
        snapshot = AIBackendSettingsSnapshot(
            isEnabled: update.isEnabled,
            baseURL: URL(string: update.baseURLText),
            hasBearerToken: hasToken
        )
    }

    func clear() async throws {
        clearCalls += 1
        snapshot = .empty
    }

    func capturedUpdates() -> [AIBackendConfigurationUpdate] {
        updates
    }

    func currentSnapshot() -> AIBackendSettingsSnapshot {
        snapshot
    }

    func clearCallCount() -> Int {
        clearCalls
    }

    func configurationLoadCallCount() -> Int {
        configurationLoadCalls
    }
}

private actor BackendSettingsTestHealthChecker: AIBackendHealthChecking {
    enum Response: Sendable {
        case success
        case status(Int)
        case genericFailure
        case gated(ResponseOutcome, BackendSettingsTestGate)

        func waiting(on gate: BackendSettingsTestGate) -> Response {
            switch self {
            case .success:
                return .gated(.success, gate)
            case let .status(code):
                return .gated(.status(code), gate)
            case .genericFailure:
                return .gated(.genericFailure, gate)
            case .gated:
                return self
            }
        }
    }

    private var responses: [Response]
    private var urls: [URL] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func check(baseURL: URL) async throws {
        urls.append(baseURL)
        guard !responses.isEmpty else {
            throw BackendSettingsModelTestError.unexpectedHealthCheck
        }
        let response = responses.removeFirst()
        switch response {
        case .success:
            return
        case let .status(code):
            throw AIBackendHealthCheckError.unexpectedStatus(code)
        case .genericFailure:
            throw BackendSettingsModelTestError.healthFailure
        case let .gated(outcome, gate):
            await gate.wait()
            try outcome.resolve()
        }
    }

    func capturedURLs() -> [URL] {
        urls
    }
}

private enum ResponseOutcome: Sendable {
    case success
    case status(Int)
    case genericFailure

    func resolve() throws {
        switch self {
        case .success:
            return
        case let .status(code):
            throw AIBackendHealthCheckError.unexpectedStatus(code)
        case .genericFailure:
            throw BackendSettingsModelTestError.healthFailure
        }
    }
}

private actor BackendSettingsTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func hasWaiter() -> Bool {
        !continuations.isEmpty
    }

    func open() {
        let waiters = continuations
        continuations.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum BackendSettingsModelTestError: Error, Sendable {
    case storeFailure
    case healthFailure
    case unexpectedHealthCheck
}
