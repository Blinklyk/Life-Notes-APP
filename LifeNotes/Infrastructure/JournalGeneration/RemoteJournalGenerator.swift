import Foundation

struct RemoteJournalGenerationRequestDTO: Encodable, Equatable, Sendable {
    struct Photo: Encodable, Equatable, Sendable {
        let annotationText: String
        let voiceTranscripts: [String]

        enum CodingKeys: String, CodingKey {
            case annotationText = "annotation_text"
            case voiceTranscripts = "voice_transcripts"
        }
    }

    struct EntrySnapshot: Encodable, Equatable, Sendable {
        let text: String
        let photos: [Photo]
        let voiceTranscripts: [String]

        enum CodingKeys: String, CodingKey {
            case text
            case photos
            case voiceTranscripts = "voice_transcripts"
        }
    }

    let requestID: UUID
    let style: String
    let entries: [EntrySnapshot]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case style
        case entries
    }

    init(requestID: UUID, request: JournalGenerationRequest) throws {
        let orderedEntries = JournalSourceOrdering.entries(request.entries)
        guard !orderedEntries.isEmpty else {
            throw JournalGenerationError.emptyEntries
        }
        guard orderedEntries.count <= 100 else {
            throw RemoteJournalGenerationError.requestTooLarge
        }
        guard let expectedUserID = orderedEntries.first?.userID,
              orderedEntries.allSatisfy({
                  $0.userID == expectedUserID && $0.dayKey == request.dayKey
              }) else {
            throw RemoteJournalGenerationError.invalidSourceScope
        }

        var allIDs: Set<UUID> = []
        var snapshots: [EntrySnapshot] = []
        for entry in orderedEntries {
            guard allIDs.insert(entry.id).inserted else {
                throw RemoteJournalGenerationError.invalidSourceScope
            }
            let normalizedText = try Self.normalized(
                entry.text,
                maximumLength: 12_000
            )

            let orderedPhotos = JournalSourceOrdering.photos(entry.photos)
            guard orderedPhotos.count <= 20,
                  orderedPhotos.allSatisfy({ $0.entryID == entry.id }) else {
                throw RemoteJournalGenerationError.invalidSourceScope
            }
            let normalizedPhotos = try orderedPhotos.map { photo in
                guard allIDs.insert(photo.id).inserted else {
                    throw RemoteJournalGenerationError.invalidSourceScope
                }
                let annotation = try Self.normalized(
                    photo.annotationText,
                    maximumLength: 4_000
                )
                return (id: photo.id, annotationText: annotation)
            }
            let photoIDs = Set(orderedPhotos.map(\.id))

            let orderedVoices = JournalSourceOrdering.voices(entry.voices)
            guard orderedVoices.count <= 21,
                  orderedVoices.allSatisfy({
                      $0.entryID == entry.id
                          && ($0.targetPhotoID.map(photoIDs.contains) ?? true)
                  }) else {
                throw RemoteJournalGenerationError.invalidSourceScope
            }
            var seenVoiceTargets: Set<UUID?> = []
            var entryVoiceTranscripts: [String] = []
            var photoVoiceTranscripts: [UUID: [String]] = [:]
            for voice in orderedVoices {
                guard allIDs.insert(voice.id).inserted else {
                    throw RemoteJournalGenerationError.invalidSourceScope
                }
                guard seenVoiceTargets.insert(voice.targetPhotoID).inserted else {
                    throw RemoteJournalGenerationError.invalidSourceScope
                }
                let transcript = try Self.normalized(
                    voice.transcriptText,
                    maximumLength: 12_000
                )
                if let targetPhotoID = voice.targetPhotoID {
                    photoVoiceTranscripts[targetPhotoID, default: []].append(transcript)
                } else {
                    entryVoiceTranscripts.append(transcript)
                }
            }
            let photos = normalizedPhotos.map { photo in
                Photo(
                    annotationText: photo.annotationText,
                    voiceTranscripts: photoVoiceTranscripts[photo.id] ?? []
                )
            }
            snapshots.append(
                EntrySnapshot(
                    text: normalizedText,
                    photos: photos,
                    voiceTranscripts: entryVoiceTranscripts
                )
            )
        }
        let filteredEntries = snapshots.compactMap { entry -> EntrySnapshot? in
            let photos = entry.photos.compactMap { photo -> Photo? in
                let voiceTranscripts = photo.voiceTranscripts.filter { !$0.isEmpty }
                guard !photo.annotationText.isEmpty || !voiceTranscripts.isEmpty else {
                    return nil
                }
                return Photo(
                    annotationText: photo.annotationText,
                    voiceTranscripts: voiceTranscripts
                )
            }
            let voiceTranscripts = entry.voiceTranscripts.filter { !$0.isEmpty }
            guard !entry.text.isEmpty || !photos.isEmpty || !voiceTranscripts.isEmpty else {
                return nil
            }
            return EntrySnapshot(
                text: entry.text,
                photos: photos,
                voiceTranscripts: voiceTranscripts
            )
        }
        guard !filteredEntries.isEmpty else {
            throw JournalGenerationError.emptyEntries
        }

        self.requestID = requestID
        style = request.style.rawValue
        entries = filteredEntries
    }

    private static func normalized(
        _ value: String,
        maximumLength: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= maximumLength else {
            throw RemoteJournalGenerationError.requestTooLarge
        }
        return normalized
    }
}

enum RemoteJournalGenerationError: LocalizedError, Equatable, Sendable {
    case invalidSourceScope
    case requestTooLarge
    case responseTooLarge
    case temporaryHTTPStatus(Int)
    case HTTPStatus(Int)
    case providerConfiguration
    case redirectNotAllowed
    case transport(URLError.Code)
    case invalidResponse
    case mismatchedRequestID

    var permitsLocalFallback: Bool {
        switch self {
        case .temporaryHTTPStatus:
            return true
        case let .transport(code):
            return Self.temporaryTransportCodes.contains(code)
        case .invalidSourceScope,
             .requestTooLarge,
             .responseTooLarge,
             .HTTPStatus,
             .providerConfiguration,
             .redirectNotAllowed,
             .invalidResponse,
             .mismatchedRequestID:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidSourceScope:
            return "记录素材校验未通过，未向后端发送内容。"
        case .requestTooLarge:
            return "这一天的文字素材超过后端单次生成上限。"
        case .responseTooLarge, .invalidResponse, .mismatchedRequestID:
            return "后端返回的日记格式无效，请检查服务版本。"
        case let .temporaryHTTPStatus(statusCode):
            return "AI 后端暂时不可用（HTTP \(statusCode)）。"
        case let .HTTPStatus(statusCode):
            switch statusCode {
            case 401, 403:
                return "后端访问令牌无效，请在“AI 与后端”中重新设置。"
            case 404:
                return "后端地址不支持日记生成接口，请检查地址。"
            case 413:
                return "这一天的文字素材超过后端请求上限。"
            case 422:
                return "后端无法处理这一天的文字素材。"
            default:
                return "后端拒绝了日记生成请求（HTTP \(statusCode)）。"
            }
        case .providerConfiguration:
            return "DeepSeek 配置或请求协议无效，请检查后端配置。"
        case .redirectNotAllowed:
            return "后端地址发生重定向，请直接填写最终 HTTPS 地址。"
        case let .transport(code):
            switch code {
            case .appTransportSecurityRequiresSecureConnection,
                 .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return "无法验证后端的 HTTPS 连接，请检查证书和地址。"
            default:
                return "暂时无法连接 AI 后端。"
            }
        }
    }

    private static let temporaryTransportCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed
    ]
}

struct RemoteJournalGenerator: Sendable {
    private struct ResponseDTO: Decodable {
        let requestID: UUID
        let title: String
        let body: String
        let model: String
        let generatorIdentifier: String

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case title
            case body
            case model
            case generatorIdentifier = "generator_identifier"
        }
    }

    private struct ErrorResponseDTO: Decodable {
        struct ErrorBody: Decodable {
            let code: String
        }

        let error: ErrorBody
    }

    static let maximumRequestBytes = 131_072
    static let maximumResponseBytes = 65_536

    let transport: any HTTPTransport
    let requestID: @Sendable () -> UUID

    init(
        transport: any HTTPTransport,
        requestID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.transport = transport
        self.requestID = requestID
    }

    func generate(
        _ request: JournalGenerationRequest,
        configuration: AIBackendConfiguration
    ) async throws -> GeneratedJournalDraft {
        let requestID = requestID()
        let payload = try RemoteJournalGenerationRequestDTO(
            requestID: requestID,
            request: request
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        guard body.count <= Self.maximumRequestBytes else {
            throw RemoteJournalGenerationError.requestTooLarge
        }

        let endpoint = configuration.baseURL.appendingAPIPath(
            "v1",
            "journals",
            "generate"
        )
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 35
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        urlRequest.setValue(
            "Bearer \(configuration.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )

        let response: HTTPTransportResponse
        do {
            response = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            throw RemoteJournalGenerationError.transport(error.code)
        } catch HTTPTransportError.responseTooLarge {
            throw RemoteJournalGenerationError.responseTooLarge
        } catch HTTPTransportError.invalidResponse {
            throw RemoteJournalGenerationError.invalidResponse
        } catch HTTPTransportError.unsupportedContentEncoding {
            throw RemoteJournalGenerationError.invalidResponse
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw RemoteJournalGenerationError.responseTooLarge
        }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 300 ... 399:
                throw RemoteJournalGenerationError.redirectNotAllowed
            case 424 where Self.backendErrorCode(in: response.data)
                == "provider_configuration_error":
                throw RemoteJournalGenerationError.providerConfiguration
            case 408, 429, 500 ... 599:
                throw RemoteJournalGenerationError.temporaryHTTPStatus(response.statusCode)
            default:
                throw RemoteJournalGenerationError.HTTPStatus(response.statusCode)
            }
        }
        let decoded: ResponseDTO
        do {
            decoded = try JSONDecoder().decode(ResponseDTO.self, from: response.data)
        } catch {
            throw RemoteJournalGenerationError.invalidResponse
        }
        guard decoded.requestID == requestID else {
            throw RemoteJournalGenerationError.mismatchedRequestID
        }
        let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let journalBody = decoded.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = decoded.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatorIdentifier = decoded.generatorIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty,
              title.utf8.count <= 120,
              !journalBody.isEmpty,
              journalBody.utf8.count <= 24_000,
              !model.isEmpty,
              model.count <= 200,
              generatorIdentifier == "deepseek.chat-completions.\(model)",
              acceptsGeneratorIdentifier(generatorIdentifier) else {
            throw RemoteJournalGenerationError.invalidResponse
        }

        let orderedEntries = JournalSourceOrdering.entries(request.entries)
        let photos = orderedEntries.flatMap { JournalSourceOrdering.photos($0.photos) }
        return GeneratedJournalDraft(
            title: title,
            blocks: [JournalBlock(text: journalBody)] + photos.map {
                JournalBlock(photo: $0, caption: $0.annotationText)
            },
            sourceFingerprint: try JournalSourceFingerprint.make(entries: orderedEntries),
            sourceEntryCount: orderedEntries.count,
            generatorIdentifier: generatorIdentifier
        )
    }

    func acceptsGeneratorIdentifier(_ identifier: String) -> Bool {
        let prefix = "deepseek.chat-completions."
        guard identifier.hasPrefix(prefix) else {
            return false
        }
        let model = identifier.dropFirst(prefix.count)
        guard let first = model.unicodeScalars.first,
              Self.isASCIIAlphaNumeric(first),
              model.count <= 200 else {
            return false
        }
        return model.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 47, 48 ... 57, 58, 65 ... 90, 95, 97 ... 122:
                return true
            default:
                return false
            }
        }
    }

    private static func backendErrorCode(in data: Data) -> String? {
        try? JSONDecoder().decode(ErrorResponseDTO.self, from: data).error.code
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }
}

struct FallbackJournalGenerator: JournalGenerator {
    let identifier = "configured.remote-first.v1"

    private let configurationStore: any AIBackendConfigurationStore
    private let remote: RemoteJournalGenerator
    private let fallback: any JournalGenerator

    init(
        configurationStore: any AIBackendConfigurationStore,
        remote: RemoteJournalGenerator,
        fallback: any JournalGenerator
    ) {
        self.configurationStore = configurationStore
        self.remote = remote
        self.fallback = fallback
    }

    func generate(_ request: JournalGenerationRequest) async throws -> GeneratedJournalDraft {
        guard let configuration = try await configurationStore.loadConfiguration(),
              configuration.isEnabled else {
            return try await fallback.generate(request)
        }

        do {
            return try await remote.generate(request, configuration: configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RemoteJournalGenerationError where error.permitsLocalFallback {
            let localDraft = try await fallback.generate(request)
            return GeneratedJournalDraft(
                title: localDraft.title,
                blocks: localDraft.blocks,
                sourceFingerprint: localDraft.sourceFingerprint,
                sourceEntryCount: localDraft.sourceEntryCount,
                generatorIdentifier: localDraft.generatorIdentifier,
                notice: "AI 服务暂时不可用，已使用本地方式生成这篇日记。"
            )
        }
    }

    func acceptsGeneratorIdentifier(_ identifier: String) -> Bool {
        remote.acceptsGeneratorIdentifier(identifier)
            || fallback.acceptsGeneratorIdentifier(identifier)
    }
}
