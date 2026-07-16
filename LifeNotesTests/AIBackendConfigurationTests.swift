import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class AIBackendConfigurationTests: XCTestCase {
    func testHTTPSBaseURLIsAcceptedAndTrailingSlashesAreNormalized() throws {
        let url = try AIBackendURLPolicy.validatedBaseURL(
            "  https://notes.example.com/api///  ",
            allowsInsecureLocalHTTP: false
        )

        XCTAssertEqual(url.absoluteString, "https://notes.example.com/api")
    }

    func testDebugHTTPAllowsOnlyCanonicalLocalPrivateAndFullTailscaleHosts() throws {
        let allowed = [
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://10.0.0.8:8080",
            "http://172.16.0.8:8080",
            "http://172.31.255.254:8080",
            "http://192.168.1.8:8080",
            "http://169.254.10.8:8080",
            "http://100.64.0.1:8080",
            "http://100.127.255.254:8080",
            "http://life-notes.local:8080",
            "http://macbook-pro.example-tailnet.ts.net:8080",
            "http://[::1]:8080",
            "http://[fe80::1]:8080",
            "http://[febf::1]:8080",
            "http://[fd7a:115c:a1e0::1]:8080"
        ]

        for rawValue in allowed {
            XCTAssertNoThrow(
                try AIBackendURLPolicy.validatedBaseURL(
                    rawValue,
                    allowsInsecureLocalHTTP: true
                ),
                rawValue
            )
        }

        let denied = [
            "http://example.com:8080",
            "http://8.8.8.8:8080",
            "http://172.15.255.255:8080",
            "http://172.32.0.1:8080",
            "http://100.63.255.255:8080",
            "http://100.128.0.1:8080",
            "http://macbook-pro:8080",
            "http://0x08080808:8080",
            "http://134744072:8080",
            "http://0177.0.0.1:8080",
            "http://127.1:8080",
            "http://[fc00::1]:8080"
        ]
        for rawValue in denied {
            XCTAssertThrowsError(
                try AIBackendURLPolicy.validatedBaseURL(
                    rawValue,
                    allowsInsecureLocalHTTP: true
                ),
                rawValue
            ) { error in
                XCTAssertEqual(
                    error as? AIBackendConfigurationError,
                    .insecureHostNotAllowed
                )
            }
        }
    }

    func testDebugDefaultMatchesDocumentedBackendPort() {
        XCTAssertEqual(
            AIBackendURLPolicy.debugDefaultBaseURLText,
            "http://127.0.0.1:8080"
        )
    }

    func testReleasePolicyRejectsHTTPIncludingLocalAndTailscaleHosts() {
        let values = [
            "http://127.0.0.1:8000",
            "http://192.168.1.8:8000",
            "http://100.100.100.100:8000",
            "http://macbook-pro:8000"
        ]

        for rawValue in values {
            XCTAssertThrowsError(
                try AIBackendURLPolicy.validatedBaseURL(
                    rawValue,
                    allowsInsecureLocalHTTP: false
                ),
                rawValue
            ) { error in
                XCTAssertEqual(
                    error as? AIBackendConfigurationError,
                    .secureTransportRequired
                )
            }
        }
    }

    func testBaseURLRejectsUserInfoQueryAndFragment() {
        let values = [
            "https://user@example.com",
            "https://user:password@example.com",
            "https://example.com?token=secret",
            "https://example.com#configuration"
        ]

        for rawValue in values {
            XCTAssertThrowsError(
                try AIBackendURLPolicy.validatedBaseURL(rawValue),
                rawValue
            ) { error in
                XCTAssertEqual(
                    error as? AIBackendConfigurationError,
                    .unsupportedURLComponents
                )
            }
        }
    }

    func testSecureStoreRoundTripsConfigurationWithoutExposingTokenInSettings() async throws {
        let dataStore = InMemorySecureConfigurationDataStore()
        let store = KeychainAIBackendConfigurationStore(
            secureDataStore: dataStore,
            allowsInsecureLocalHTTP: true
        )
        let token = "0123456789abcdef-private-token"

        let initiallyLoadedConfiguration = try await store.loadConfiguration()
        let initiallyLoadedSettings = try await store.loadSettings()
        XCTAssertNil(initiallyLoadedConfiguration)
        XCTAssertEqual(initiallyLoadedSettings, .empty)

        try await store.save(
            AIBackendConfigurationUpdate(
                isEnabled: true,
                baseURLText: "http://127.0.0.1:8080/",
                bearerTokenReplacement: token
            )
        )

        let loadedConfiguration = try await store.loadConfiguration()
        let loadedSettings = try await store.loadSettings()
        XCTAssertEqual(
            loadedConfiguration,
            AIBackendConfiguration(
                isEnabled: true,
                baseURL: URL(string: "http://127.0.0.1:8080")!,
                bearerToken: token
            )
        )
        XCTAssertEqual(
            loadedSettings,
            AIBackendSettingsSnapshot(
                isEnabled: true,
                baseURL: URL(string: "http://127.0.0.1:8080")!,
                hasBearerToken: true
            )
        )
    }

    func testBearerTokenValidationMatchesBackendASCIIContract() throws {
        XCTAssertEqual(
            try AIBackendURLPolicy.validatedBearerToken("  0123456789abcdef-token  "),
            "0123456789abcdef-token"
        )
        for token in [
            "0123456789abcde",
            "0123456789abcdef-令牌",
            "0123456789abcdef token",
            String(repeating: "a", count: 513)
        ] {
            XCTAssertThrowsError(try AIBackendURLPolicy.validatedBearerToken(token)) { error in
                XCTAssertEqual(
                    error as? AIBackendConfigurationError,
                    .invalidBearerToken
                )
            }
        }
    }

    func testDisabledDebugHTTPConfigurationDoesNotBlockReleaseLocalFallback() async throws {
        let dataStore = InMemorySecureConfigurationDataStore()
        dataStore.replace(
            with: Data(
                """
                {"schemaVersion":1,"isEnabled":false,"baseURL":"http://127.0.0.1:8080","bearerToken":"0123456789abcdef-token"}
                """.utf8
            )
        )
        let releaseStore = KeychainAIBackendConfigurationStore(
            secureDataStore: dataStore,
            allowsInsecureLocalHTTP: false
        )

        let runtimeConfiguration = try await releaseStore.loadConfiguration()
        XCTAssertNil(runtimeConfiguration)
        do {
            _ = try await releaseStore.loadSettings()
            XCTFail("设置页仍应暴露旧 HTTP 配置需要修复")
        } catch let error as AIBackendConfigurationError {
            XCTAssertEqual(error, .secureTransportRequired)
        }
    }

    func testSecureStoreUpdatesAndPreservesTokenWhenReplacementIsOmitted() async throws {
        let dataStore = InMemorySecureConfigurationDataStore()
        let store = KeychainAIBackendConfigurationStore(
            secureDataStore: dataStore,
            allowsInsecureLocalHTTP: true
        )
        let originalToken = "0123456789abcdef-original"

        try await store.save(
            AIBackendConfigurationUpdate(
                isEnabled: true,
                baseURLText: "http://localhost:8080",
                bearerTokenReplacement: originalToken
            )
        )
        try await store.save(
            AIBackendConfigurationUpdate(
                isEnabled: true,
                baseURLText: "http://macbook-pro.example-tailnet.ts.net:9000/api/",
                bearerTokenReplacement: nil
            )
        )

        let preservedConfiguration = try await store.loadConfiguration()
        let preserved = try XCTUnwrap(preservedConfiguration)
        XCTAssertEqual(
            preserved.baseURL.absoluteString,
            "http://macbook-pro.example-tailnet.ts.net:9000/api"
        )
        XCTAssertEqual(preserved.bearerToken, originalToken)

        let replacementToken = "fedcba9876543210-replacement"
        try await store.save(
            AIBackendConfigurationUpdate(
                isEnabled: true,
                baseURLText: preserved.baseURL.absoluteString,
                bearerTokenReplacement: replacementToken
            )
        )
        let updated = try await store.loadConfiguration()
        XCTAssertEqual(updated?.bearerToken, replacementToken)
    }

    func testSecureStoreClearRemovesCompleteConfigurationAndIsIdempotent() async throws {
        let dataStore = InMemorySecureConfigurationDataStore()
        let store = KeychainAIBackendConfigurationStore(
            secureDataStore: dataStore,
            allowsInsecureLocalHTTP: false
        )
        try await store.save(
            AIBackendConfigurationUpdate(
                isEnabled: true,
                baseURLText: "https://notes.example.com",
                bearerTokenReplacement: "0123456789abcdef-token"
            )
        )

        try await store.clear()
        try await store.clear()

        let loadedConfiguration = try await store.loadConfiguration()
        let loadedSettings = try await store.loadSettings()
        XCTAssertNil(loadedConfiguration)
        XCTAssertEqual(loadedSettings, .empty)
        XCTAssertNil(dataStore.snapshot())
    }

    func testSecureStoreFailsClosedForMalformedAndUnknownSchemaData() async throws {
        let dataStore = InMemorySecureConfigurationDataStore()
        let store = KeychainAIBackendConfigurationStore(
            secureDataStore: dataStore,
            allowsInsecureLocalHTTP: true
        )

        dataStore.replace(with: Data("not-json".utf8))
        await assertCorrupted(store)

        dataStore.replace(
            with: Data(
                """
                {"schemaVersion":2,"isEnabled":true,"baseURL":"https://notes.example.com","bearerToken":"0123456789abcdef-token"}
                """.utf8
            )
        )
        await assertCorrupted(store)
    }

    private func assertCorrupted(
        _ store: KeychainAIBackendConfigurationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.loadConfiguration()
            XCTFail("损坏配置必须 fail closed", file: file, line: line)
        } catch let error as AIBackendConfigurationError {
            XCTAssertEqual(
                error,
                .corruptedSecureConfiguration,
                file: file,
                line: line
            )
        } catch {
            XCTFail("返回了错误类型: \(error)", file: file, line: line)
        }
    }
}

private final class InMemorySecureConfigurationDataStore: SecureConfigurationDataStore,
    @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }

    func replace(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
