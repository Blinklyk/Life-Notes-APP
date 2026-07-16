import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class RemoteJournalGeneratorTests: XCTestCase {
    func testRequestDTOUsesExactPrivacyWhitelistAndCanonicalOrdering() throws {
        let request = makeRequest()
        let requestID = uuid(90)
        let dto = try RemoteJournalGenerationRequestDTO(
            requestID: requestID,
            request: request
        )
        let data = try JSONEncoder().encode(dto)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(json.keys),
            ["request_id", "style", "entries"]
        )
        XCTAssertEqual(json["request_id"] as? String, requestID.uuidString)
        XCTAssertEqual(json["style"] as? String, WritingStyle.delicate.rawValue)

        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            entries.compactMap { $0["text"] as? String },
            ["较早的正文", "稍晚的正文"]
        )
        for entry in entries {
            XCTAssertEqual(Set(entry.keys), ["text", "photos", "voice_transcripts"])
        }

        let earlierPhotos = try XCTUnwrap(entries[0]["photos"] as? [[String: Any]])
        XCTAssertEqual(
            earlierPhotos.compactMap { $0["annotation_text"] as? String },
            ["第二张批注", "第一张批注"]
        )
        XCTAssertTrue(
            earlierPhotos.allSatisfy {
                Set($0.keys) == ["annotation_text", "voice_transcripts"]
            }
        )
        XCTAssertEqual(
            entries[0]["voice_transcripts"] as? [String],
            ["全局语音转写"]
        )
        XCTAssertEqual(
            earlierPhotos[0]["voice_transcripts"] as? [String],
            []
        )
        XCTAssertEqual(
            earlierPhotos[1]["voice_transcripts"] as? [String],
            ["照片语音转写"]
        )
        let laterPhotos = try XCTUnwrap(entries[1]["photos"] as? [[String: Any]])
        XCTAssertEqual(laterPhotos.count, 1)
        XCTAssertEqual(laterPhotos[0]["annotation_text"] as? String, "稍晚的照片")
        XCTAssertEqual(laterPhotos[0]["voice_transcripts"] as? [String], [])
        XCTAssertEqual(entries[1]["voice_transcripts"] as? [String], [])

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        let sentinels = [
            uuid(240).uuidString,
            uuid(241).uuidString,
            uuid(11).uuidString,
            uuid(12).uuidString,
            uuid(31).uuidString,
            uuid(32).uuidString,
            uuid(33).uuidString,
            uuid(41).uuidString,
            uuid(42).uuidString,
            try JournalSourceFingerprint.make(entries: request.entries).rawValue,
            "PRIVATE_TIMEZONE_SENTINEL",
            "PRIVATE_ORIGINAL_PATH_SENTINEL",
            "PRIVATE_THUMBNAIL_PATH_SENTINEL",
            "PRIVATE_AUDIO_PATH_SENTINEL",
            "PRIVATE_CONTENT_TYPE_SENTINEL",
            "PRIVATE_LOCALE_SENTINEL"
        ]
        for sentinel in sentinels {
            XCTAssertFalse(encoded.contains(sentinel), sentinel)
        }
        let forbiddenKeys = [
            "day_key",
            "source_fingerprint",
            "source_draft_id",
            "user_id",
            "entry_id",
            "photo_id",
            "voice_id",
            "target_photo_id",
            "created_at",
            "updated_at",
            "creation_time_zone_identifier",
            "revision",
            "voices",
            "transcript_text"
        ]
        for key in forbiddenKeys {
            XCTAssertFalse(encoded.contains("\"\(key)\""), key)
        }
    }

    func testRequestDTOFiltersUnreadableEntriesPhotosAndVoiceTranscripts() throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let purePhotoEntryID = uuid(10)
        let purePhoto = makePhoto(
            idSuffix: 20,
            entryID: purePhotoEntryID,
            sortIndex: 0,
            annotation: " \n "
        )
        let purePhotoEntry = makeEntry(
            idSuffix: 10,
            day: day,
            userID: uuid(200),
            createdAt: Date(timeIntervalSince1970: 100),
            text: " \n ",
            photos: [purePhoto]
        )
        let readableEntryID = uuid(11)
        let emptyPhoto = makePhoto(
            idSuffix: 30,
            entryID: readableEntryID,
            sortIndex: 0,
            annotation: "\t"
        )
        let readableEntry = makeEntry(
            idSuffix: 11,
            day: day,
            userID: uuid(200),
            createdAt: Date(timeIntervalSince1970: 200),
            text: "唯一可读正文",
            photos: [emptyPhoto],
            voices: [
                makeVoice(
                    idSuffix: 21,
                    entryID: readableEntryID,
                    sortIndex: 0,
                    transcript: " \n "
                ),
                makeVoice(
                    idSuffix: 22,
                    entryID: readableEntryID,
                    targetPhotoID: emptyPhoto.id,
                    sortIndex: 1,
                    transcript: "\t"
                )
            ]
        )
        let dto = try RemoteJournalGenerationRequestDTO(
            requestID: uuid(90),
            request: JournalGenerationRequest(
                dayKey: day,
                entries: [readableEntry, purePhotoEntry],
                style: .natural
            )
        )

        let data = try JSONEncoder().encode(dto)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["text"] as? String, "唯一可读正文")
        let photos = try XCTUnwrap(entries[0]["photos"] as? [[String: Any]])
        XCTAssertTrue(photos.isEmpty)
        XCTAssertEqual(entries[0]["voice_transcripts"] as? [String], [])

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(purePhoto.id.uuidString))
        XCTAssertFalse(encoded.contains(emptyPhoto.id.uuidString))
    }

    func testRequestDTORejectsContentWithoutAnyReadableText() throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let entryID = uuid(10)
        let photo = makePhoto(
            idSuffix: 20,
            entryID: entryID,
            sortIndex: 0,
            annotation: " \n "
        )
        let entry = makeEntry(
            idSuffix: 10,
            day: day,
            userID: uuid(200),
            text: "\t",
            photos: [photo],
            voices: [
                makeVoice(
                    idSuffix: 21,
                    entryID: entryID,
                    targetPhotoID: photo.id,
                    sortIndex: 0,
                    transcript: " \n "
                )
            ]
        )

        XCTAssertThrowsError(
            try RemoteJournalGenerationRequestDTO(
                requestID: uuid(90),
                request: JournalGenerationRequest(
                    dayKey: day,
                    entries: [entry],
                    style: .natural
                )
            )
        ) { error in
            XCTAssertEqual(error as? JournalGenerationError, .emptyEntries)
        }
    }

    func testRequestDTOReportsMoreThanOneHundredEntriesAsTooLarge() throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let entries = (0..<101).map { index in
            makeEntry(
                idSuffix: UInt8(index + 1),
                day: day,
                userID: uuid(200),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                text: "第 \(index + 1) 条"
            )
        }

        XCTAssertThrowsError(
            try RemoteJournalGenerationRequestDTO(
                requestID: uuid(90),
                request: JournalGenerationRequest(
                    dayKey: day,
                    entries: entries,
                    style: .natural
                )
            )
        ) { error in
            XCTAssertEqual(error as? RemoteJournalGenerationError, .requestTooLarge)
        }
    }

    func testRequestDTORejectsMixedOrForgedSourceScope() throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let otherDay = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 16))
        let valid = makeEntry(idSuffix: 1, day: day, userID: uuid(200), text: "有效素材")
        let mixedUser = makeEntry(
            idSuffix: 2,
            day: day,
            userID: uuid(201),
            text: "其他用户"
        )
        let mixedDay = makeEntry(
            idSuffix: 3,
            day: otherDay,
            userID: uuid(200),
            text: "其他日期"
        )
        let forgedPhoto = makePhoto(
            idSuffix: 51,
            entryID: uuid(250),
            sortIndex: 0,
            annotation: " \n "
        )
        let entryWithForgedPhoto = makeEntry(
            idSuffix: 4,
            day: day,
            userID: uuid(200),
            text: "\t",
            photos: [forgedPhoto],
            remapAttachmentOwners: false
        )
        let forgedVoice = makeVoice(
            idSuffix: 52,
            entryID: uuid(250),
            sortIndex: 0,
            transcript: " \n "
        )
        let entryWithForgedVoice = makeEntry(
            idSuffix: 5,
            day: day,
            userID: uuid(200),
            text: "\t",
            voices: [forgedVoice],
            remapAttachmentOwners: false
        )
        let danglingVoice = makeVoice(
            idSuffix: 53,
            entryID: uuid(6),
            targetPhotoID: uuid(199),
            sortIndex: 0,
            transcript: " \n "
        )
        let entryWithDanglingTarget = makeEntry(
            idSuffix: 6,
            day: day,
            userID: uuid(200),
            text: "\t",
            voices: [danglingVoice]
        )
        let duplicateIDPhoto = makePhoto(
            idSuffix: 7,
            entryID: uuid(7),
            sortIndex: 0,
            annotation: " \n "
        )
        let entryWithDuplicateID = makeEntry(
            idSuffix: 7,
            day: day,
            userID: uuid(200),
            text: "\t",
            photos: [duplicateIDPhoto]
        )
        let duplicateGlobalVoiceTarget = makeEntry(
            idSuffix: 8,
            day: day,
            userID: uuid(200),
            text: "\t",
            voices: [
                makeVoice(
                    idSuffix: 54,
                    entryID: uuid(8),
                    sortIndex: 0,
                    transcript: " \n "
                ),
                makeVoice(
                    idSuffix: 55,
                    entryID: uuid(8),
                    sortIndex: 1,
                    transcript: "\t"
                )
            ]
        )
        let targetPhoto = makePhoto(
            idSuffix: 56,
            entryID: uuid(9),
            sortIndex: 0,
            annotation: " \n "
        )
        let duplicatePhotoVoiceTarget = makeEntry(
            idSuffix: 9,
            day: day,
            userID: uuid(200),
            text: "\t",
            photos: [targetPhoto],
            voices: [
                makeVoice(
                    idSuffix: 57,
                    entryID: uuid(9),
                    targetPhotoID: targetPhoto.id,
                    sortIndex: 0,
                    transcript: " \n "
                ),
                makeVoice(
                    idSuffix: 58,
                    entryID: uuid(9),
                    targetPhotoID: targetPhoto.id,
                    sortIndex: 1,
                    transcript: "\t"
                )
            ]
        )

        let invalidEntrySets = [
            [valid, mixedUser],
            [valid, mixedDay],
            [entryWithForgedPhoto],
            [entryWithForgedVoice],
            [entryWithDanglingTarget],
            [entryWithDuplicateID],
            [duplicateGlobalVoiceTarget],
            [duplicatePhotoVoiceTarget]
        ]
        for entries in invalidEntrySets {
            XCTAssertThrowsError(
                try RemoteJournalGenerationRequestDTO(
                    requestID: uuid(90),
                    request: JournalGenerationRequest(
                        dayKey: day,
                        entries: entries,
                        style: .natural
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? RemoteJournalGenerationError,
                    .invalidSourceScope
                )
            }
        }
    }

    func testRemotePOSTEchoesRequestIDAndStitchesLocalPhotosAndFingerprint() async throws {
        let request = makeRequest()
        let requestID = uuid(90)
        let token = "0123456789abcdef-backend-token"
        let responseData = try makeResponseData(requestID: requestID)
        let transport = RecordingHTTPTransport(
            behaviors: [
                .response(
                    statusCode: 200,
                    data: responseData,
                    finalURL: URL(string: "https://backend.example.com/root/v1/journals/generate")
                )
            ]
        )
        let generator = RemoteJournalGenerator(
            transport: transport,
            requestID: { requestID }
        )

        let draft = try await generator.generate(
            request,
            configuration: AIBackendConfiguration(
                isEnabled: true,
                baseURL: URL(string: "https://backend.example.com/root")!,
                bearerToken: token
            )
        )

        let requests = await transport.capturedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.url?.absoluteString, "https://backend.example.com/root/v1/journals/generate")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(sent.timeoutInterval, 35)

        let body = try XCTUnwrap(sent.httpBody)
        let sentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(sentJSON["request_id"] as? String, requestID.uuidString)
        XCTAssertFalse(try XCTUnwrap(String(data: body, encoding: .utf8)).contains(token))

        XCTAssertEqual(draft.title, "远程标题")
        XCTAssertEqual(draft.blocks.first?.text, "远程正文")
        XCTAssertEqual(
            draft.blocks.dropFirst().compactMap(\.photo),
            [uuid(32), uuid(31), uuid(33)].compactMap { id in
                request.entries.flatMap(\.photos).first { $0.id == id }
            }
        )
        XCTAssertEqual(
            draft.blocks.dropFirst().compactMap(\.caption),
            ["第二张批注", "第一张批注", "稍晚的照片"]
        )
        XCTAssertEqual(
            draft.sourceFingerprint,
            try JournalSourceFingerprint.make(entries: request.entries)
        )
        XCTAssertEqual(draft.sourceEntryCount, 2)
        XCTAssertEqual(
            draft.generatorIdentifier,
            "deepseek.chat-completions.deepseek-v4-pro"
        )
        XCTAssertNil(draft.notice)
    }

    func testCompositeFallsBackForRateLimitServerErrorsAndTimeout() async throws {
        let request = makeRequest()
        let localDraft = try await LocalJournalGenerator().generate(request)
        let temporaryBehaviors: [RecordingHTTPTransport.Behavior] = [
            .response(statusCode: 408, data: Data(), finalURL: nil),
            .response(statusCode: 429, data: Data(), finalURL: nil),
            .response(
                statusCode: 502,
                data: Data(#"{"error":{"code":"invalid_provider_response"}}"#.utf8),
                finalURL: nil
            ),
            .response(statusCode: 503, data: Data(), finalURL: nil),
            .urlError(.timedOut)
        ]
        let requestID = uuid(90)

        for behavior in temporaryBehaviors {
            let transport = RecordingHTTPTransport(behaviors: [behavior])
            let local = CountingJournalGenerator(draft: localDraft)
            let composite = FallbackJournalGenerator(
                configurationStore: FixedAIBackendConfigurationStore(
                    configuration: enabledConfiguration
                ),
                remote: RemoteJournalGenerator(
                    transport: transport,
                    requestID: { requestID }
                ),
                fallback: local
            )

            let generated = try await composite.generate(request)

            let generationCount = await local.generationCount()
            XCTAssertEqual(generationCount, 1)
            XCTAssertEqual(generated.title, localDraft.title)
            XCTAssertEqual(generated.blocks, localDraft.blocks)
            XCTAssertEqual(generated.generatorIdentifier, localDraft.generatorIdentifier)
            XCTAssertEqual(
                generated.notice,
                "AI 服务暂时不可用，已使用本地方式生成这篇日记。"
            )
        }
    }

    func testCompositeDoesNotFallbackForPermanentProtocolTLSOrCancellationFailures() async throws {
        let request = makeRequest()
        let localDraft = try await LocalJournalGenerator().generate(request)
        let requestID = uuid(90)
        let cases: [(RecordingHTTPTransport.Behavior, ExpectedFailure)] = [
            (
                .response(statusCode: 400, data: Data(), finalURL: nil),
                .remote(.HTTPStatus(400))
            ),
            (
                .response(
                    statusCode: 424,
                    data: Data(
                        #"{"error":{"code":"provider_configuration_error"}}"#.utf8
                    ),
                    finalURL: nil
                ),
                .remote(.providerConfiguration)
            ),
            (
                .response(
                    statusCode: 424,
                    data: Data(#"{"error":{"code":"different_error"}}"#.utf8),
                    finalURL: nil
                ),
                .remote(.HTTPStatus(424))
            ),
            (
                .urlError(.serverCertificateUntrusted),
                .remote(.transport(.serverCertificateUntrusted))
            ),
            (
                .transportError(.responseTooLarge),
                .remote(.responseTooLarge)
            ),
            (
                .transportError(.invalidResponse),
                .remote(.invalidResponse)
            ),
            (
                .response(statusCode: 200, data: Data("not-json".utf8), finalURL: nil),
                .remote(.invalidResponse)
            ),
            (
                .response(
                    statusCode: 200,
                    data: try makeResponseData(requestID: uuid(91)),
                    finalURL: nil
                ),
                .remote(.mismatchedRequestID)
            ),
            (
                .response(statusCode: 307, data: Data(), finalURL: nil),
                .remote(.redirectNotAllowed)
            ),
            (.cancelled, .cancelled)
        ]

        for (behavior, expectedFailure) in cases {
            let transport = RecordingHTTPTransport(behaviors: [behavior])
            let local = CountingJournalGenerator(draft: localDraft)
            let composite = FallbackJournalGenerator(
                configurationStore: FixedAIBackendConfigurationStore(
                    configuration: enabledConfiguration
                ),
                remote: RemoteJournalGenerator(
                    transport: transport,
                    requestID: { requestID }
                ),
                fallback: local
            )

            do {
                _ = try await composite.generate(request)
                XCTFail("永久错误、TLS、协议错误或取消不应回退")
            } catch is CancellationError {
                XCTAssertEqual(expectedFailure, .cancelled)
            } catch let error as RemoteJournalGenerationError {
                XCTAssertEqual(expectedFailure, .remote(error))
            } catch {
                XCTFail("返回了错误类型: \(error)")
            }
            let generationCount = await local.generationCount()
            XCTAssertEqual(generationCount, 0)
            if expectedFailure == .remote(.providerConfiguration) {
                XCTAssertEqual(
                    RemoteJournalGenerationError.providerConfiguration.localizedDescription,
                    "DeepSeek 配置或请求协议无效，请检查后端配置。"
                )
            }
        }
    }

    func testCompositeValidatesDeepSeekAndLocalGeneratorIdentifiers() async throws {
        let transport = RecordingHTTPTransport(behaviors: [])
        let composite = FallbackJournalGenerator(
            configurationStore: FixedAIBackendConfigurationStore(configuration: nil),
            remote: RemoteJournalGenerator(transport: transport),
            fallback: LocalJournalGenerator()
        )

        XCTAssertTrue(
            composite.acceptsGeneratorIdentifier(
                "deepseek.chat-completions.deepseek-v4-pro"
            )
        )
        XCTAssertTrue(composite.acceptsGeneratorIdentifier("local.rule-based.v1"))
        XCTAssertFalse(composite.acceptsGeneratorIdentifier("openai.responses.gpt-5.6"))
        XCTAssertFalse(composite.acceptsGeneratorIdentifier("deepseek.chat-completions."))
        XCTAssertFalse(composite.acceptsGeneratorIdentifier("deepseek.chat-completions.-invalid"))
        XCTAssertFalse(
            composite.acceptsGeneratorIdentifier(
                "deepseek.chat-completions.deepseek-v4-pro\n"
            )
        )
        XCTAssertFalse(
            composite.acceptsGeneratorIdentifier(
                "deepseek.chat-completions." + String(repeating: "m", count: 201)
            )
        )

        let generated = try await composite.generate(makeRequest())
        let capturedRequests = await transport.capturedRequests()
        XCTAssertEqual(generated.generatorIdentifier, "local.rule-based.v1")
        XCTAssertNil(generated.notice)
        XCTAssertTrue(capturedRequests.isEmpty)
    }

    func testURLSessionTransportCancelsStreamingResponseAtByteLimit() async throws {
        BoundedResponseURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration,
            maximumResponseBytes: 2_048
        )
        let request = URLRequest(url: URL(string: "https://bounded-response.test/stream")!)

        do {
            _ = try await transport.data(for: request)
            XCTFail("超过硬上限的响应必须立即失败")
        } catch let error as HTTPTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        for _ in 0..<200 where !BoundedResponseURLProtocol.state.snapshot().wasStopped {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = BoundedResponseURLProtocol.state.snapshot()
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertLessThan(snapshot.emittedChunks, 100)
        XCTAssertEqual(snapshot.acceptEncoding, "identity")
    }

    func testURLSessionTransportRejectsCompressedResponseBeforeReadingBytes() async throws {
        BoundedResponseURLProtocol.state.reset(contentEncoding: "gzip")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://bounded-response.test/gzip")!)

        do {
            _ = try await transport.data(for: request)
            XCTFail("压缩响应必须在读取正文前失败")
        } catch let error as HTTPTransportError {
            XCTAssertEqual(error, .unsupportedContentEncoding)
        }

        for _ in 0..<200 where !BoundedResponseURLProtocol.state.snapshot().wasStopped {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = BoundedResponseURLProtocol.state.snapshot()
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertEqual(snapshot.emittedChunks, 0)
        XCTAssertEqual(snapshot.acceptEncoding, "identity")
    }

    func testRequestAndResponseTextLimitsUseUTF8Bytes() async throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let oversizedEntry = makeEntry(
            idSuffix: 80,
            day: day,
            userID: uuid(200),
            text: String(repeating: "👨‍👩‍👧‍👦", count: 500)
        )
        XCTAssertThrowsError(
            try RemoteJournalGenerationRequestDTO(
                requestID: uuid(90),
                request: JournalGenerationRequest(
                    dayKey: day,
                    entries: [oversizedEntry],
                    style: .natural
                )
            )
        ) { error in
            XCTAssertEqual(error as? RemoteJournalGenerationError, .requestTooLarge)
        }

        let request = makeRequest()
        let requestID = uuid(90)
        for (title, body) in [
            (String(repeating: "中", count: 41), "正文"),
            ("标题", String(repeating: "中", count: 8_001))
        ] {
            let responseData = try makeResponseData(
                requestID: requestID,
                title: title,
                body: body
            )
            let generator = RemoteJournalGenerator(
                transport: RecordingHTTPTransport(
                    behaviors: [.response(statusCode: 200, data: responseData, finalURL: nil)]
                ),
                requestID: { requestID }
            )
            do {
                _ = try await generator.generate(request, configuration: enabledConfiguration)
                XCTFail("超过 UTF-8 字节上限的返回值必须拒绝")
            } catch let error as RemoteJournalGenerationError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    private var enabledConfiguration: AIBackendConfiguration {
        AIBackendConfiguration(
            isEnabled: true,
            baseURL: URL(string: "https://backend.example.com")!,
            bearerToken: "0123456789abcdef-backend-token"
        )
    }

    private func makeRequest() -> JournalGenerationRequest {
        let day = DayKey(year: 2026, month: 7, day: 15)!
        let userID = uuid(240)
        let firstEntryID = uuid(11)
        let firstPhoto = makePhoto(
            idSuffix: 31,
            entryID: firstEntryID,
            sortIndex: 1,
            annotation: "第一张批注"
        )
        let secondPhoto = makePhoto(
            idSuffix: 32,
            entryID: firstEntryID,
            sortIndex: 0,
            annotation: "第二张批注"
        )
        let firstEntry = makeEntry(
            idSuffix: 11,
            day: day,
            userID: userID,
            sourceDraftID: uuid(241),
            createdAt: Date(timeIntervalSince1970: 100),
            text: "  较早的正文  ",
            photos: [firstPhoto, secondPhoto],
            voices: [
                makeVoice(
                    idSuffix: 41,
                    entryID: firstEntryID,
                    targetPhotoID: firstPhoto.id,
                    sortIndex: 1,
                    transcript: "  照片语音转写  "
                ),
                makeVoice(
                    idSuffix: 42,
                    entryID: firstEntryID,
                    sortIndex: 0,
                    transcript: "  全局语音转写  "
                )
            ]
        )
        let secondEntryID = uuid(12)
        let secondEntry = makeEntry(
            idSuffix: 12,
            day: day,
            userID: userID,
            createdAt: Date(timeIntervalSince1970: 200),
            text: "稍晚的正文",
            photos: [
                makePhoto(
                    idSuffix: 33,
                    entryID: secondEntryID,
                    sortIndex: 0,
                    annotation: "稍晚的照片"
                )
            ]
        )
        return JournalGenerationRequest(
            dayKey: day,
            entries: [secondEntry, firstEntry],
            style: .delicate
        )
    }

    private func makeEntry(
        idSuffix: UInt8,
        day: DayKey,
        userID: UUID,
        sourceDraftID: UUID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        text: String,
        photos: [PhotoAttachment] = [],
        voices: [VoiceAttachment] = [],
        remapAttachmentOwners: Bool = true
    ) -> Entry {
        let id = uuid(idSuffix)
        return Entry(
            id: id,
            userID: userID,
            sourceDraftID: sourceDraftID,
            dayKey: day,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 9_876_543),
            revision: 987,
            creationTimeZoneIdentifier: "PRIVATE_TIMEZONE_SENTINEL",
            text: text,
            photos: photos.map { photo in
                PhotoAttachment(
                    id: photo.id,
                    entryID: remapAttachmentOwners ? id : photo.entryID,
                    sortIndex: photo.sortIndex,
                    annotationText: photo.annotationText,
                    contentTypeIdentifier: photo.contentTypeIdentifier,
                    pixelWidth: photo.pixelWidth,
                    pixelHeight: photo.pixelHeight,
                    byteCount: photo.byteCount,
                    originalRelativePath: photo.originalRelativePath,
                    thumbnailRelativePath: photo.thumbnailRelativePath
                )
            },
            voices: voices.map { voice in
                VoiceAttachment(
                    id: voice.id,
                    entryID: remapAttachmentOwners ? id : voice.entryID,
                    targetPhotoID: voice.targetPhotoID,
                    sortIndex: voice.sortIndex,
                    durationMilliseconds: voice.durationMilliseconds,
                    contentTypeIdentifier: voice.contentTypeIdentifier,
                    byteCount: voice.byteCount,
                    originalRelativePath: voice.originalRelativePath,
                    transcriptText: voice.transcriptText,
                    transcriptionStatus: voice.transcriptionStatus,
                    transcriptionSource: voice.transcriptionSource,
                    sourceLocaleIdentifier: voice.sourceLocaleIdentifier,
                    isTranscriptUserEdited: voice.isTranscriptUserEdited
                )
            }
        )
    }

    private func makePhoto(
        idSuffix: UInt8,
        entryID: UUID,
        sortIndex: Int,
        annotation: String
    ) -> PhotoAttachment {
        PhotoAttachment(
            id: uuid(idSuffix),
            entryID: entryID,
            sortIndex: sortIndex,
            annotationText: annotation,
            contentTypeIdentifier: "PRIVATE_CONTENT_TYPE_SENTINEL",
            pixelWidth: 98_765,
            pixelHeight: 87_654,
            byteCount: 76_543,
            originalRelativePath: "PRIVATE_ORIGINAL_PATH_SENTINEL",
            thumbnailRelativePath: "PRIVATE_THUMBNAIL_PATH_SENTINEL"
        )
    }

    private func makeVoice(
        idSuffix: UInt8,
        entryID: UUID,
        targetPhotoID: UUID? = nil,
        sortIndex: Int,
        transcript: String
    ) -> VoiceAttachment {
        VoiceAttachment(
            id: uuid(idSuffix),
            entryID: entryID,
            targetPhotoID: targetPhotoID,
            sortIndex: sortIndex,
            durationMilliseconds: 65_432,
            contentTypeIdentifier: "PRIVATE_CONTENT_TYPE_SENTINEL",
            byteCount: 54_321,
            originalRelativePath: "PRIVATE_AUDIO_PATH_SENTINEL",
            transcriptText: transcript,
            transcriptionStatus: .completed,
            transcriptionSource: .onDevice,
            sourceLocaleIdentifier: "PRIVATE_LOCALE_SENTINEL",
            isTranscriptUserEdited: true
        )
    }

    private func makeResponseData(
        requestID: UUID,
        title: String = "  远程标题  ",
        body: String = "  远程正文  ",
        model: String = "deepseek-v4-pro",
        generatorIdentifier: String? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "request_id": requestID.uuidString,
                "title": title,
                "body": body,
                "model": model,
                "generator_identifier": generatorIdentifier
                    ?? "deepseek.chat-completions.\(model)"
            ],
            options: [.sortedKeys]
        )
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}

private enum ExpectedFailure: Equatable {
    case remote(RemoteJournalGenerationError)
    case cancelled
}

private actor RecordingHTTPTransport: HTTPTransport {
    enum Behavior: Sendable {
        case response(statusCode: Int, data: Data, finalURL: URL?)
        case urlError(URLError.Code)
        case transportError(HTTPTransportError)
        case cancelled
    }

    private var behaviors: [Behavior]
    private var requests: [URLRequest] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !behaviors.isEmpty else {
            throw RemoteJournalGeneratorTestError.unexpectedRequest
        }
        let behavior = behaviors.removeFirst()
        switch behavior {
        case let .response(statusCode, data, finalURL):
            return HTTPTransportResponse(
                data: data,
                statusCode: statusCode,
                finalURL: finalURL
            )
        case let .urlError(code):
            throw URLError(code)
        case let .transportError(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private struct FixedAIBackendConfigurationStore: AIBackendConfigurationStore {
    let configuration: AIBackendConfiguration?

    func loadConfiguration() async throws -> AIBackendConfiguration? {
        configuration
    }

    func loadSettings() async throws -> AIBackendSettingsSnapshot {
        guard let configuration else {
            return .empty
        }
        return AIBackendSettingsSnapshot(
            isEnabled: configuration.isEnabled,
            baseURL: configuration.baseURL,
            hasBearerToken: !configuration.bearerToken.isEmpty
        )
    }

    func save(_ update: AIBackendConfigurationUpdate) async throws {
        throw RemoteJournalGeneratorTestError.unsupportedOperation
    }

    func clear() async throws {
        throw RemoteJournalGeneratorTestError.unsupportedOperation
    }
}

private actor CountingJournalGenerator: JournalGenerator {
    nonisolated let identifier: String
    private let draft: GeneratedJournalDraft
    private var count = 0

    init(identifier: String = "local.test.v1", draft: GeneratedJournalDraft) {
        self.identifier = identifier
        self.draft = draft
    }

    func generate(_ request: JournalGenerationRequest) async throws -> GeneratedJournalDraft {
        count += 1
        return draft
    }

    func generationCount() -> Int {
        count
    }
}

private enum RemoteJournalGeneratorTestError: Error {
    case unexpectedRequest
    case unsupportedOperation
}

private final class BoundedResponseURLProtocolState: @unchecked Sendable {
    struct Snapshot {
        let emittedChunks: Int
        let wasStopped: Bool
        let contentEncoding: String?
        let acceptEncoding: String?
    }

    private let lock = NSLock()
    private var emittedChunks = 0
    private var wasStopped = false
    private var contentEncoding: String?
    private var acceptEncoding: String?

    func reset(contentEncoding: String? = nil) {
        lock.lock()
        emittedChunks = 0
        wasStopped = false
        self.contentEncoding = contentEncoding
        acceptEncoding = nil
        lock.unlock()
    }

    func capture(acceptEncoding: String?) {
        lock.lock()
        self.acceptEncoding = acceptEncoding
        lock.unlock()
    }

    func markChunkEmitted() {
        lock.lock()
        emittedChunks += 1
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        wasStopped = true
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            emittedChunks: emittedChunks,
            wasStopped: wasStopped,
            contentEncoding: contentEncoding,
            acceptEncoding: acceptEncoding
        )
    }
}

private final class BoundedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = BoundedResponseURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bounded-response.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.capture(
            acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding")
        )
        let producer = BoundedResponseProducer(owner: self)
        DispatchQueue.global(qos: .userInitiated).async {
            producer.run()
        }
    }

    override func stopLoading() {
        Self.state.markStopped()
    }

    fileprivate func emitResponse() {
        let stateSnapshot = Self.state.snapshot()
        var headers = ["Content-Type": "application/json"]
        if let contentEncoding = stateSnapshot.contentEncoding {
            headers["Content-Encoding"] = contentEncoding
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
              ) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Thread.sleep(forTimeInterval: 0.01)
        for _ in 0..<100 {
            guard !Self.state.snapshot().wasStopped else {
                return
            }
            Self.state.markChunkEmitted()
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 1_024))
            Thread.sleep(forTimeInterval: 0.005)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class BoundedResponseProducer: @unchecked Sendable {
    private weak var owner: BoundedResponseURLProtocol?

    init(owner: BoundedResponseURLProtocol) {
        self.owner = owner
    }

    func run() {
        owner?.emitResponse()
    }
}
