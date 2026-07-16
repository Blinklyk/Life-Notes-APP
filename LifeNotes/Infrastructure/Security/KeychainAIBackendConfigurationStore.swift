import Foundation
import Security

protocol SecureConfigurationDataStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

enum SecureConfigurationDataStoreError: Error, Equatable, Sendable {
    case keychainStatus(OSStatus)
    case unexpectedResult
}

struct SystemKeychainConfigurationDataStore: SecureConfigurationDataStore {
    private let service: String
    private let account: String

    init(
        service: String = "com.blinklyk.LifeNotes.ai-backend",
        account: String = "configuration.v1"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureConfigurationDataStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw SecureConfigurationDataStoreError.unexpectedResult
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecureConfigurationDataStoreError.keychainStatus(updateStatus)
        }

        var item = baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureConfigurationDataStoreError.keychainStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureConfigurationDataStoreError.keychainStatus(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}

actor KeychainAIBackendConfigurationStore: AIBackendConfigurationStore {
    private struct StoredConfiguration: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
        let baseURL: String
        let bearerToken: String?
    }

    private let secureDataStore: any SecureConfigurationDataStore
    private let allowsInsecureLocalHTTP: Bool

    init(
        secureDataStore: any SecureConfigurationDataStore = SystemKeychainConfigurationDataStore(),
        allowsInsecureLocalHTTP: Bool = AIBackendURLPolicy.allowsInsecureLocalHTTP
    ) {
        self.secureDataStore = secureDataStore
        self.allowsInsecureLocalHTTP = allowsInsecureLocalHTTP
    }

    func loadConfiguration() throws -> AIBackendConfiguration? {
        guard let stored = try loadStoredConfiguration() else {
            return nil
        }
        guard stored.isEnabled else {
            return nil
        }
        let baseURL = try AIBackendURLPolicy.validatedBaseURL(
            stored.baseURL,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
        let token: String
        if let storedToken = stored.bearerToken {
            token = try AIBackendURLPolicy.validatedBearerToken(storedToken)
        } else {
            throw AIBackendConfigurationError.missingBearerToken
        }
        return AIBackendConfiguration(
            isEnabled: stored.isEnabled,
            baseURL: baseURL,
            bearerToken: token
        )
    }

    func loadSettings() throws -> AIBackendSettingsSnapshot {
        guard let stored = try loadStoredConfiguration() else {
            return .empty
        }
        let baseURL = try AIBackendURLPolicy.validatedBaseURL(
            stored.baseURL,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
        let hasToken: Bool
        if let token = stored.bearerToken {
            _ = try AIBackendURLPolicy.validatedBearerToken(token)
            hasToken = true
        } else {
            hasToken = false
        }
        if stored.isEnabled, !hasToken {
            throw AIBackendConfigurationError.missingBearerToken
        }
        return AIBackendSettingsSnapshot(
            isEnabled: stored.isEnabled,
            baseURL: baseURL,
            hasBearerToken: hasToken
        )
    }

    func save(_ update: AIBackendConfigurationUpdate) throws {
        let baseURL = try AIBackendURLPolicy.validatedBaseURL(
            update.baseURLText,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
        let existing = try loadStoredConfiguration()
        let replacement = update.bearerTokenReplacement?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token: String?
        if let replacement, !replacement.isEmpty {
            token = try AIBackendURLPolicy.validatedBearerToken(replacement)
        } else {
            token = existing?.bearerToken
        }
        if update.isEnabled, token == nil {
            throw AIBackendConfigurationError.missingBearerToken
        }

        let stored = StoredConfiguration(
            schemaVersion: 1,
            isEnabled: update.isEnabled,
            baseURL: baseURL.absoluteString,
            bearerToken: token
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try secureDataStore.write(encoder.encode(stored))
    }

    func clear() throws {
        try secureDataStore.delete()
    }

    private func loadStoredConfiguration() throws -> StoredConfiguration? {
        guard let data = try secureDataStore.read() else {
            return nil
        }
        do {
            let stored = try JSONDecoder().decode(StoredConfiguration.self, from: data)
            guard stored.schemaVersion == 1 else {
                throw AIBackendConfigurationError.corruptedSecureConfiguration
            }
            return stored
        } catch let error as AIBackendConfigurationError {
            throw error
        } catch {
            throw AIBackendConfigurationError.corruptedSecureConfiguration
        }
    }
}
