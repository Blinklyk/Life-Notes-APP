import Foundation

struct AIBackendConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let baseURL: URL
    let bearerToken: String
}

struct AIBackendSettingsSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let baseURL: URL?
    let hasBearerToken: Bool

    static let empty = AIBackendSettingsSnapshot(
        isEnabled: false,
        baseURL: nil,
        hasBearerToken: false
    )
}

struct AIBackendConfigurationUpdate: Equatable, Sendable {
    let isEnabled: Bool
    let baseURLText: String
    let bearerTokenReplacement: String?
}

protocol AIBackendConfigurationStore: Sendable {
    func loadConfiguration() async throws -> AIBackendConfiguration?
    func loadSettings() async throws -> AIBackendSettingsSnapshot
    func save(_ update: AIBackendConfigurationUpdate) async throws
    func clear() async throws
}

enum AIBackendConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedURLComponents
    case secureTransportRequired
    case insecureHostNotAllowed
    case missingBearerToken
    case invalidBearerToken
    case corruptedSecureConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请输入完整的后端地址。"
        case .unsupportedURLComponents:
            return "后端地址不能包含账号、密码、查询参数或片段。"
        case .secureTransportRequired:
            return "当前版本只允许使用 HTTPS 后端。"
        case .insecureHostNotAllowed:
            return "Debug 模式下的 HTTP 只允许连接本机、局域网或 Tailscale 地址。"
        case .missingBearerToken:
            return "启用 AI 后端前，请填写访问令牌。"
        case .invalidBearerToken:
            return "访问令牌需要 16–512 个可见 ASCII 字符。"
        case .corruptedSecureConfiguration:
            return "保存的后端配置已损坏，请清除后重新设置。"
        }
    }
}

enum AIBackendURLPolicy {
    static let debugDefaultBaseURLText = "http://127.0.0.1:8080"

    static var allowsInsecureLocalHTTP: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func validatedBaseURL(
        _ rawValue: String,
        allowsInsecureLocalHTTP: Bool = allowsInsecureLocalHTTP
    ) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let componentHost = components.host?.lowercased(),
              !componentHost.isEmpty,
              scheme == "https" || scheme == "http" else {
            throw AIBackendConfigurationError.invalidURL
        }
        let host = componentHost.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AIBackendConfigurationError.unsupportedURLComponents
        }

        if scheme == "http" {
            guard allowsInsecureLocalHTTP else {
                throw AIBackendConfigurationError.secureTransportRequired
            }
            guard isAllowedInsecureHost(host) else {
                throw AIBackendConfigurationError.insecureHostNotAllowed
            }
        }

        if components.path == "/" {
            components.path = ""
        } else {
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        guard let url = components.url else {
            throw AIBackendConfigurationError.invalidURL
        }
        return url
    }

    static func validatedBearerToken(_ rawValue: String) throws -> String {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 16,
              token.count <= 512,
              token.unicodeScalars.allSatisfy({ scalar in
                  33 ... 126 ~= scalar.value
              }) else {
            throw AIBackendConfigurationError.invalidBearerToken
        }
        return token
    }

    private static func isAllowedInsecureHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }
        if (host.hasSuffix(".local") || host.hasSuffix(".ts.net")),
           host.first != "." {
            return true
        }
        if isAllowedInsecureIPv6Literal(host) {
            return true
        }

        guard let octets = canonicalIPv4Octets(host) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254):
            return true
        case (172, 16 ... 31):
            return true
        case (100, 64 ... 127):
            return true
        default:
            return false
        }
    }

    private static func canonicalIPv4Octets(_ host: String) -> [Int]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            return nil
        }
        var octets: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ 48 ... 57 ~= $0.value }),
                  (component.count == 1 || component.first != "0"),
                  let octet = Int(component),
                  0 ... 255 ~= octet else {
                return nil
            }
            octets.append(octet)
        }
        return octets
    }

    private static func isAllowedInsecureIPv6Literal(_ host: String) -> Bool {
        if host.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }
        guard let firstHextetText = host.split(separator: ":", maxSplits: 1).first,
              let firstHextet = UInt16(firstHextetText, radix: 16) else {
            return false
        }
        return firstHextet & 0xffc0 == 0xfe80
    }
}

extension URL {
    func appendingAPIPath(_ components: String...) -> URL {
        components.reduce(self) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: false)
        }
    }
}
