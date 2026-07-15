import Foundation
import SwiftData
import XCTest
@testable import LifeNotes

final class SwiftDataDayWorkspaceTests: XCTestCase {
    private let userID = UUID(uuidString: "68BDB82A-B998-4DD0-B844-8FE1C9539B9B")!

    func testTextEntrySavesAndReadsForItsOriginalDay() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-12T16:30:00Z")
        let draft = try NewEntry(text: "  夜里忽然想起一件小事。  ")

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: shanghai)
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let utcDay = DayKey(containing: createdAt, in: TimeZone(identifier: "UTC")!)
        let entriesForUTCDay = try await workspace.entries(for: utcDay, userID: userID)
        let entriesForAnotherUser = try await workspace.entries(
            for: saved.dayKey,
            userID: UUID()
        )

        XCTAssertEqual(saved.text, "夜里忽然想起一件小事。")
        XCTAssertTrue(saved.photos.isEmpty)
        XCTAssertEqual(saved.creationTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(saved.dayKey, DayKey(year: 2026, month: 7, day: 13))
        XCTAssertEqual(entries, [saved])
        XCTAssertTrue(entriesForUTCDay.isEmpty)
        XCTAssertTrue(entriesForAnotherUser.isEmpty)
    }

    func testSourceDraftIDPersistsAndOnlyMatchesItsOwner() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let sourceDraftID = UUID(uuidString: "C6AB1CB1-7C16-46E7-B4BF-A6664488A56E")!
        let draft = try NewEntry(
            sourceDraftID: sourceDraftID,
            text: "带提交来源的记录"
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let reloaded = try XCTUnwrap(entries.first)
        let isCommittedForOwner = try await workspace.hasCommittedDraft(
            id: sourceDraftID,
            userID: userID
        )
        let isCommittedForAnotherUser = try await workspace.hasCommittedDraft(
            id: sourceDraftID,
            userID: UUID()
        )
        let isAnotherDraftCommitted = try await workspace.hasCommittedDraft(
            id: UUID(),
            userID: userID
        )

        XCTAssertEqual(saved.sourceDraftID, sourceDraftID)
        XCTAssertEqual(reloaded.sourceDraftID, sourceDraftID)
        XCTAssertTrue(isCommittedForOwner)
        XCTAssertFalse(isCommittedForAnotherUser)
        XCTAssertFalse(isAnotherDraftCommitted)
    }

    func testImageOnlyEntrySavesWithoutGlobalText() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let photoID = UUID(uuidString: "32922104-33B5-4A6A-91EF-14278117DB83")!
        let photo = makePhoto(
            id: photoID,
            annotationText: "  窗边的光  ",
            originalRelativePath: "original/one.heic",
            thumbnailRelativePath: "thumbnail/one.jpg"
        )
        let draft = try NewEntry(text: " \n ", photos: [photo])

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)

        XCTAssertEqual(saved.text, "")
        XCTAssertEqual(saved.photos.count, 1)
        XCTAssertEqual(saved.photos.first?.id, photoID)
        XCTAssertEqual(saved.photos.first?.entryID, saved.id)
        XCTAssertEqual(saved.photos.first?.sortIndex, 0)
        XCTAssertEqual(saved.photos.first?.annotationText, "窗边的光")
        XCTAssertEqual(entries, [saved])
    }

    func testTextAndTwoPhotosPreservePhotoOrderAndAnnotations() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let firstID = UUID(uuidString: "DD718CD7-0A92-4605-9744-D3C6A7F0F3D7")!
        let secondID = UUID(uuidString: "F42BF1D4-5296-45EB-B72C-8494D4E9A301")!
        let draft = try NewEntry(
            text: "  今天走了很远。  ",
            photos: [
                makePhoto(
                    id: firstID,
                    annotationText: "  第一站  ",
                    originalRelativePath: "original/first.heic",
                    thumbnailRelativePath: "thumbnail/first.jpg"
                ),
                makePhoto(
                    id: secondID,
                    annotationText: "\n第二站\n",
                    originalRelativePath: "original/second.png",
                    thumbnailRelativePath: "thumbnail/second.jpg"
                )
            ]
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T05:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let reloaded = try XCTUnwrap(entries.first)

        XCTAssertEqual(reloaded.text, "今天走了很远。")
        XCTAssertEqual(reloaded.photos.map(\.id), [firstID, secondID])
        XCTAssertEqual(reloaded.photos.map(\.sortIndex), [0, 1])
        XCTAssertEqual(reloaded.photos.map(\.annotationText), ["第一站", "第二站"])
        XCTAssertEqual(
            reloaded.photos.map(\.originalRelativePath),
            ["original/first.heic", "original/second.png"]
        )
        XCTAssertTrue(reloaded.photos.allSatisfy { $0.entryID == reloaded.id })
    }

    func testVoiceOnlyEntryPreservesOriginalAudioAndFailedTranscript() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let voiceID = UUID(uuidString: "A16A7A0F-8CD8-47F6-A63E-226149B65E6A")!
        let draft = try NewEntry(
            text: " \n ",
            voices: [
                makeVoice(
                    id: voiceID,
                    originalRelativePath: "Audio/\(voiceID.uuidString)/original.m4a",
                    transcriptText: "",
                    transcriptionStatus: .failed,
                    sourceLocaleIdentifier: "zh-CN"
                )
            ]
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T05:30:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let reloadedVoice = try XCTUnwrap(entries.first?.voices.first)

        XCTAssertEqual(saved.text, "")
        XCTAssertEqual(saved.voices.count, 1)
        XCTAssertEqual(reloadedVoice.id, voiceID)
        XCTAssertEqual(reloadedVoice.entryID, saved.id)
        XCTAssertEqual(reloadedVoice.sortIndex, 0)
        XCTAssertEqual(reloadedVoice.durationMilliseconds, 12_345)
        XCTAssertEqual(reloadedVoice.contentTypeIdentifier, "public.mpeg-4-audio")
        XCTAssertEqual(reloadedVoice.byteCount, 4_096)
        XCTAssertEqual(
            reloadedVoice.originalRelativePath,
            "Audio/\(voiceID.uuidString)/original.m4a"
        )
        XCTAssertEqual(reloadedVoice.transcriptionStatus, .failed)
        XCTAssertNil(reloadedVoice.transcriptionSource)
        XCTAssertTrue(reloadedVoice.transcriptText.isEmpty)
        XCTAssertFalse(reloadedVoice.isTranscriptUserEdited)
        XCTAssertEqual(reloadedVoice.sourceLocaleIdentifier, "zh-CN")
    }

    func testVoicesPreserveOrderPhotoTargetAndTranscriptOnlyState() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let photoID = UUID(uuidString: "6EC6E769-0C65-464A-9866-6FEE00A2F41D")!
        let transcriptOnlyVoiceID = UUID(uuidString: "74BF937F-B3BC-4F30-BF93-7E9C689AE50B")!
        let retainedVoiceID = UUID(uuidString: "C85B77CB-52EF-4F42-9BB7-3478BD919585")!
        let draft = try NewEntry(
            text: "一张照片和两段语音",
            photos: [
                makePhoto(
                    id: photoID,
                    originalRelativePath: "original/voice-target.heic",
                    thumbnailRelativePath: "thumbnail/voice-target.jpg"
                )
            ],
            voices: [
                makeVoice(
                    id: transcriptOnlyVoiceID,
                    targetPhotoID: photoID,
                    originalRelativePath: nil,
                    transcriptText: "  照片里的风很大。  ",
                    transcriptionStatus: .completed,
                    transcriptionSource: .manual,
                    isTranscriptUserEdited: true,
                    sourceLocaleIdentifier: "zh-Hans-CN"
                ),
                makeVoice(
                    id: retainedVoiceID,
                    originalRelativePath: "Audio/\(retainedVoiceID.uuidString)/original.m4a",
                    transcriptText: "稍后继续转写",
                    transcriptionStatus: .pending
                )
            ]
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T06:00:00Z"),
                timeZone: shanghai
            )
        )
        let reloadedEntries = try await workspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        let reloaded = try XCTUnwrap(reloadedEntries.first)

        XCTAssertEqual(reloaded.voices.map(\.id), [transcriptOnlyVoiceID, retainedVoiceID])
        XCTAssertEqual(reloaded.voices.map(\.sortIndex), [0, 1])
        XCTAssertEqual(reloaded.voices.first?.targetPhotoID, photoID)
        XCTAssertNil(reloaded.voices.first?.originalRelativePath)
        XCTAssertNil(reloaded.voices.first?.contentTypeIdentifier)
        XCTAssertEqual(reloaded.voices.first?.byteCount, 0)
        XCTAssertEqual(reloaded.voices.first?.transcriptText, "照片里的风很大。")
        XCTAssertEqual(reloaded.voices.first?.transcriptionStatus, .completed)
        XCTAssertEqual(reloaded.voices.first?.transcriptionSource, .manual)
        XCTAssertTrue(reloaded.voices.first?.isTranscriptUserEdited == true)
        XCTAssertEqual(reloaded.voices.first?.sourceLocaleIdentifier, "zh-Hans-CN")
        XCTAssertNil(reloaded.voices.last?.targetPhotoID)
        XCTAssertEqual(reloaded.voices.last?.transcriptionStatus, .pending)
    }

    func testVoiceValidationRejectsInvalidDurationAndIncompleteContent() throws {
        XCTAssertThrowsError(
            try NewEntry(
                text: "",
                voices: [
                    NewVoiceAttachment(
                        durationMilliseconds: 0,
                        transcriptText: "有文字",
                        transcriptionStatus: .completed
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? EntryValidationError, .invalidVoiceDuration)
        }

        XCTAssertThrowsError(
            try NewEntry(
                text: "",
                voices: [NewVoiceAttachment(durationMilliseconds: 1_000)]
            )
        ) { error in
            XCTAssertEqual(
                error as? EntryValidationError,
                .transcriptOnlyVoiceRequiresTranscript
            )
        }

        XCTAssertThrowsError(
            try NewEntry(
                text: "",
                voices: [
                    NewVoiceAttachment(
                        durationMilliseconds: 1_000,
                        originalRelativePath: "Audio/incomplete/original.m4a"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? EntryValidationError, .retainedVoiceRequiresMetadata)
        }
    }

    func testCreateIsIdempotentForSameUsersSourceDraftID() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let sourceDraftID = UUID(uuidString: "28859942-CE1A-464A-AB09-585BC344A712")!
        let firstVoiceID = UUID(uuidString: "05341C3C-D763-45EA-B4EE-3EA46F1CBB07")!
        let context = RecordingContext(
            instant: try instant("2026-07-13T07:00:00Z"),
            timeZone: shanghai
        )

        let first = try await workspace.create(
            NewEntry(
                sourceDraftID: sourceDraftID,
                text: "第一次提交",
                voices: [
                    makeVoice(
                        id: firstVoiceID,
                        originalRelativePath: "Audio/\(firstVoiceID.uuidString)/original.m4a",
                        transcriptText: "第一次的语音",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: context
        )
        let duplicateAttempt = try await workspace.create(
            NewEntry(
                sourceDraftID: sourceDraftID,
                text: "不应覆盖第一次提交",
                voices: [
                    makeVoice(
                        originalRelativePath: nil,
                        transcriptText: "不应新增的语音",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: context
        )
        let entries = try await workspace.entries(for: first.dayKey, userID: userID)

        XCTAssertEqual(duplicateAttempt, first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "第一次提交")
        XCTAssertEqual(entries.first?.voices.map(\.id), [firstVoiceID])

        let otherUserEntry = try await workspace.create(
            NewEntry(sourceDraftID: sourceDraftID, text: "其他用户可以使用相同草稿 ID"),
            userID: UUID(uuidString: "12FA60E8-F57C-471C-AC0E-07BC246C0CE5")!,
            context: context
        )
        XCTAssertNotEqual(otherUserEntry.id, first.id)
    }

    func testConcurrentWorkspacesCreateSourceDraftOnlyOnce() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let firstWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let secondWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let requestedUserID = userID
        let sourceDraftID = UUID()
        let draft = try NewEntry(
            sourceDraftID: sourceDraftID,
            text: "两个 context 同时提交"
        )
        let context = RecordingContext(
            instant: try instant("2026-07-13T07:30:00Z"),
            timeZone: shanghai
        )

        async let first = firstWorkspace.create(
            draft,
            userID: requestedUserID,
            context: context
        )
        async let second = secondWorkspace.create(
            draft,
            userID: requestedUserID,
            context: context
        )
        let (firstEntry, secondEntry) = try await (first, second)
        let entries = try await firstWorkspace.entries(
            for: firstEntry.dayKey,
            userID: requestedUserID
        )

        XCTAssertEqual(firstEntry.id, secondEntry.id)
        XCTAssertEqual(entries.map(\.id), [firstEntry.id])
    }

    func testEntriesRemainIsolatedAndAreReadNewestFirst() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        _ = try await workspace.create(
            NewEntry(text: "较早的记录"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T01:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "较晚的记录",
                photos: [makePhoto(originalRelativePath: "late.heic", thumbnailRelativePath: "late.jpg")]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(text: "另一天"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-14T08:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(text: "其他用户"),
            userID: UUID(),
            context: RecordingContext(
                instant: try instant("2026-07-13T06:00:00Z"),
                timeZone: shanghai
            )
        )

        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 13))
        let entries = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["较晚的记录", "较早的记录"])
        XCTAssertEqual(entries.first?.photos.count, 1)
        XCTAssertTrue(entries.last?.photos.isEmpty == true)
    }

    func testPhotoIDsReturnOnlyRequestedUsersPhotosAcrossAllDays() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let firstPhotoID = UUID(uuidString: "5D4C5A26-981D-4EDF-BD9F-F48A1B55F814")!
        let secondPhotoID = UUID(uuidString: "34B0BA94-9C95-4A7B-B3AF-C68A516D88B0")!
        let otherUsersPhotoID = UUID(uuidString: "29420D12-70DF-4EE5-9472-8C52EE94F51B")!
        let otherUserID = UUID(uuidString: "52590590-9270-4276-B8E7-79E5427AFD80")!

        _ = try await workspace.create(
            NewEntry(
                text: "第一天",
                photos: [
                    makePhoto(
                        id: firstPhotoID,
                        originalRelativePath: "original/first-day.heic",
                        thumbnailRelativePath: "thumbnail/first-day.jpg"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "第二天",
                photos: [
                    makePhoto(
                        id: secondPhotoID,
                        originalRelativePath: "original/second-day.heic",
                        thumbnailRelativePath: "thumbnail/second-day.jpg"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-14T04:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "其他用户",
                photos: [
                    makePhoto(
                        id: otherUsersPhotoID,
                        originalRelativePath: "original/other-user.heic",
                        thumbnailRelativePath: "thumbnail/other-user.jpg"
                    )
                ]
            ),
            userID: otherUserID,
            context: RecordingContext(
                instant: try instant("2026-07-15T04:00:00Z"),
                timeZone: shanghai
            )
        )

        let photoIDs = try await workspace.photoIDs(userID: userID)
        let allPhotoIDs = try await workspace.allPhotoIDs()

        XCTAssertEqual(photoIDs, [firstPhotoID, secondPhotoID])
        XCTAssertFalse(photoIDs.contains(otherUsersPhotoID))
        XCTAssertEqual(allPhotoIDs, [firstPhotoID, secondPhotoID, otherUsersPhotoID])
    }

    func testRetainedVoiceIDsExcludeTranscriptOnlyAndRespectUsers() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let retainedVoiceID = UUID(uuidString: "1ACD882B-CE25-4E55-91F6-45617A269644")!
        let transcriptOnlyVoiceID = UUID(uuidString: "1666E78A-0A75-4640-BA02-D5547BC2B9CD")!
        let otherUsersVoiceID = UUID(uuidString: "6544EFC3-50F2-4109-AD6F-EE73537BD3BE")!
        let otherUserID = UUID(uuidString: "B8D5F210-9F2D-4B39-AAD8-CF28AFD3472F")!
        let context = RecordingContext(
            instant: try instant("2026-07-13T08:00:00Z"),
            timeZone: shanghai
        )

        _ = try await workspace.create(
            NewEntry(
                text: "当前用户语音",
                voices: [
                    makeVoice(
                        id: retainedVoiceID,
                        originalRelativePath: "Audio/\(retainedVoiceID.uuidString)/original.m4a"
                    ),
                    makeVoice(
                        id: transcriptOnlyVoiceID,
                        originalRelativePath: nil,
                        transcriptText: "只保留转写",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: context
        )
        _ = try await workspace.create(
            NewEntry(
                text: "其他用户语音",
                voices: [
                    makeVoice(
                        id: otherUsersVoiceID,
                        originalRelativePath: "Audio/\(otherUsersVoiceID.uuidString)/original.m4a"
                    )
                ]
            ),
            userID: otherUserID,
            context: context
        )

        let retainedVoiceIDs = try await workspace.retainedVoiceIDs(userID: userID)
        let allRetainedVoiceIDs = try await workspace.allRetainedVoiceIDs()

        XCTAssertEqual(retainedVoiceIDs, [retainedVoiceID])
        XCTAssertEqual(allRetainedVoiceIDs, [retainedVoiceID, otherUsersVoiceID])
        XCTAssertFalse(allRetainedVoiceIDs.contains(transcriptOnlyVoiceID))
    }

    @MainActor
    func testRetainedVoiceIDsRejectMismatchedPathAfterValidatingOwnerScope() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let recordID = UUID()
        let pathID = UUID()
        let entryID = UUID()
        let context = ModelContext(container)
        context.insert(
            EntryRecord(
                id: entryID,
                userID: userID,
                dayKeyRawValue: 20260713,
                createdAt: Date(timeIntervalSince1970: 1_752_384_000),
                updatedAt: Date(timeIntervalSince1970: 1_752_384_000),
                creationTimeZoneIdentifier: "Asia/Shanghai",
                text: "合法的语音附件 owner"
            )
        )
        context.insert(
            VoiceAttachmentRecord(
                id: recordID,
                entryID: entryID,
                userID: userID,
                dayKeyRawValue: 20260713,
                targetPhotoID: nil,
                sortIndex: 0,
                durationMilliseconds: 1_000,
                contentTypeIdentifier: "public.mpeg-4-audio",
                byteCount: 1_024,
                originalRelativePath: VoiceAudioStoragePath.relativePath(for: pathID),
                transcriptText: "",
                transcriptionStatusRawValue: VoiceTranscriptionStatus.failed.rawValue,
                isTranscriptUserEdited: false
            )
        )
        try context.save()

        do {
            _ = try await workspace.allRetainedVoiceIDs()
            XCTFail("record ID 与 path ID 不一致时不应返回不可信的保留集合")
        } catch let PersistenceMappingError.invalidVoiceStorageReference(path) {
            XCTAssertEqual(path, VoiceAudioStoragePath.relativePath(for: pathID))
        }
    }

    func testUpdateVoiceTranscriptChecksOwnerAndAdvancesEntryUpdatedAt() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let voiceID = UUID(uuidString: "B3F1CA21-9482-43CB-8721-E3C3FD04A2D1")!
        let createdAt = try instant("2026-07-13T08:00:00Z")
        let updatedAt = try instant("2026-07-13T09:30:00Z")
        let saved = try await workspace.create(
            NewEntry(
                text: "等待修正转写",
                voices: [
                    makeVoice(
                        id: voiceID,
                        originalRelativePath: "Audio/\(voiceID.uuidString)/original.m4a",
                        transcriptionStatus: .failed
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: shanghai)
        )

        do {
            _ = try await workspace.updateVoiceTranscript(
                id: voiceID,
                userID: UUID(),
                text: "不能修改其他用户的转写",
                status: .completed,
                source: .manual,
                isUserEdited: true,
                sourceLocaleIdentifier: "zh-CN",
                updatedAt: updatedAt
            )
            XCTFail("其他用户不应能修改该语音转写")
        } catch {
            XCTAssertEqual(error as? DayWorkspaceError, .voiceAttachmentNotFound)
        }

        let updatedVoice = try await workspace.updateVoiceTranscript(
            id: voiceID,
            userID: userID,
            text: "  用户修正后的转写。  ",
            status: .completed,
            source: .manual,
            isUserEdited: true,
            sourceLocaleIdentifier: "  zh-Hans-CN  ",
            updatedAt: updatedAt
        )
        let reloadedEntries = try await workspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        let reloadedEntry = try XCTUnwrap(reloadedEntries.first)

        XCTAssertEqual(updatedVoice.transcriptText, "用户修正后的转写。")
        XCTAssertEqual(updatedVoice.transcriptionStatus, .completed)
        XCTAssertEqual(updatedVoice.transcriptionSource, .manual)
        XCTAssertTrue(updatedVoice.isTranscriptUserEdited)
        XCTAssertEqual(updatedVoice.sourceLocaleIdentifier, "zh-Hans-CN")
        XCTAssertEqual(reloadedEntry.updatedAt, updatedAt)
        XCTAssertEqual(reloadedEntry.voices, [updatedVoice])
    }

    func testEntriesWithSameCreationTimeUseStableIDDescendingOrder() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        let context = RecordingContext(instant: createdAt, timeZone: shanghai)

        let firstEntry = try await workspace.create(
            NewEntry(text: "第一条"),
            userID: userID,
            context: context
        )
        let secondEntry = try await workspace.create(
            NewEntry(text: "第二条"),
            userID: userID,
            context: context
        )
        let thirdEntry = try await workspace.create(
            NewEntry(text: "第三条"),
            userID: userID,
            context: context
        )
        let createdEntries = [firstEntry, secondEntry, thirdEntry]
        let day = DayKey(containing: createdAt, in: shanghai)
        let expectedIDs = createdEntries.map(\.id).sorted {
            $0.uuidString > $1.uuidString
        }

        let firstRead = try await workspace.entries(for: day, userID: userID)
        let secondRead = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(firstRead.map(\.id), expectedIDs)
        XCTAssertEqual(secondRead.map(\.id), expectedIDs)
    }

    func testEmptyDraftIsRejected() {
        XCTAssertThrowsError(try NewEntry(text: " \n\t ")) { error in
            XCTAssertEqual(error as? EntryValidationError, .emptyEntry)
        }
    }

    func testPersistentStoreWithPhotosCanBeReopened() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("test.store")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        let photoID = UUID(uuidString: "DA88B311-0DD4-4C56-BD49-1758A48BB956")!
        let voiceID = UUID(uuidString: "FB838947-453A-4EA2-93E2-2B072A506C8D")!

        try await writePersistentEntry(
            storeURL: storeURL,
            draft: NewEntry(
                text: "重启后还在这里",
                photos: [
                    makePhoto(
                        id: photoID,
                        annotationText: "原图也在",
                        originalRelativePath: "original/reopen.heic",
                        thumbnailRelativePath: "thumbnail/reopen.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: voiceID,
                        originalRelativePath: "Audio/\(voiceID.uuidString)/original.m4a",
                        transcriptText: "重启后转写也在",
                        transcriptionStatus: .completed,
                        isTranscriptUserEdited: true,
                        sourceLocaleIdentifier: "zh-CN"
                    )
                ]
            ),
            createdAt: createdAt,
            timeZone: shanghai
        )

        let reopenedContainer = try ModelContainerFactory.make(
            configurationName: "PersistenceRestart",
            storeURL: storeURL
        )
        let reopenedWorkspace = SwiftDataDayWorkspace(modelContainer: reopenedContainer)
        let day = DayKey(containing: createdAt, in: shanghai)
        let entries = try await reopenedWorkspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["重启后还在这里"])
        XCTAssertEqual(entries.first?.photos.map(\.id), [photoID])
        XCTAssertEqual(entries.first?.photos.first?.annotationText, "原图也在")
        XCTAssertEqual(entries.first?.voices.map(\.id), [voiceID])
        XCTAssertEqual(entries.first?.voices.first?.transcriptText, "重启后转写也在")
        XCTAssertTrue(entries.first?.voices.first?.isTranscriptUserEdited == true)
        XCTAssertEqual(entries.first?.voices.first?.sourceLocaleIdentifier, "zh-CN")
    }

    func testLegacyTextStoreOpensWithExpandedSchema() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("legacy.store")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        let legacySchema = Schema(versionedSchema: LegacyEntrySchemaV1.self)
        let legacyEntity = try XCTUnwrap(
            legacySchema.entitiesByName["EntryRecord"]
        )
        XCTAssertNil(legacyEntity.attributesByName["revision"])
        XCTAssertEqual(
            legacyEntity.name,
            Schema([EntryRecord.self]).entitiesByName["EntryRecord"]?.name
        )
        try writeLegacyEntry(
            storeURL: storeURL,
            text: "旧版本的文字记录",
            createdAt: createdAt,
            timeZone: shanghai
        )

        let migratedContainer = try ModelContainerFactory.make(
            configurationName: "LegacyMigration",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: migratedContainer)
        let day = DayKey(containing: createdAt, in: shanghai)
        let entries = try await workspace.entries(for: day, userID: userID)
        let migrated = try XCTUnwrap(entries.first)
        let updated = try await workspace.updateEntry(
            id: migrated.id,
            userID: userID,
            edit: EntryEdit(
                expectedRevision: migrated.revision,
                text: "旧版本迁移后仍可编辑",
                photoAnnotations: [],
                voiceTranscripts: []
            ),
            updatedAt: createdAt.addingTimeInterval(60)
        )

        XCTAssertEqual(entries.map(\.text), ["旧版本的文字记录"])
        XCTAssertEqual(migrated.revision, 0)
        XCTAssertTrue(migrated.photos.isEmpty)
        XCTAssertTrue(migrated.voices.isEmpty)
        XCTAssertEqual(updated.text, "旧版本迁移后仍可编辑")
        XCTAssertEqual(updated.revision, 1)
    }

    func testAtomicEntryEditUpdatesCompleteEditableSnapshotAndNoOpKeepsRevision() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let photoA = UUID()
        let photoB = UUID()
        let retainedVoice = UUID()
        let transcriptOnlyVoice = UUID()
        let saved = try await workspace.create(
            NewEntry(
                text: "编辑前正文",
                photos: [
                    makePhoto(
                        id: photoA,
                        annotationText: "旧批注 A",
                        originalRelativePath: "original/edit-a.heic",
                        thumbnailRelativePath: "thumbnail/edit-a.jpg"
                    ),
                    makePhoto(
                        id: photoB,
                        annotationText: "旧批注 B",
                        originalRelativePath: "original/edit-b.heic",
                        thumbnailRelativePath: "thumbnail/edit-b.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: retainedVoice,
                        originalRelativePath: VoiceAudioStoragePath.relativePath(
                            for: retainedVoice
                        ),
                        transcriptText: "旧转写 A",
                        transcriptionStatus: .completed
                    ),
                    makeVoice(
                        id: transcriptOnlyVoice,
                        targetPhotoID: photoB,
                        originalRelativePath: nil,
                        transcriptText: "旧转写 B",
                        transcriptionStatus: .completed,
                        transcriptionSource: .manual,
                        isTranscriptUserEdited: true
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: shanghai
            )
        )
        let updatedAt = try instant("2026-07-13T10:00:00Z")
        let edit = EntryEdit(
            expectedRevision: saved.revision,
            text: "  编辑后正文  ",
            photoAnnotations: [
                EntryPhotoAnnotationEdit(photoID: photoB, annotationText: " 新批注 B "),
                EntryPhotoAnnotationEdit(photoID: photoA, annotationText: " 新批注 A ")
            ],
            voiceTranscripts: [
                EntryVoiceTranscriptEdit(
                    voiceID: transcriptOnlyVoice,
                    transcriptText: " 新转写 B ",
                    transcriptionStatus: .completed,
                    transcriptionSource: .manual,
                    isTranscriptUserEdited: true,
                    sourceLocaleIdentifier: " zh-Hans-CN "
                ),
                EntryVoiceTranscriptEdit(
                    voiceID: retainedVoice,
                    transcriptText: " 新转写 A ",
                    transcriptionStatus: .completed,
                    transcriptionSource: .onDevice,
                    isTranscriptUserEdited: false,
                    sourceLocaleIdentifier: "zh-CN"
                )
            ]
        )

        let updated = try await workspace.updateEntry(
            id: saved.id,
            userID: userID,
            edit: edit,
            updatedAt: updatedAt
        )
        let noOp = try await workspace.updateEntry(
            id: saved.id,
            userID: userID,
            edit: EntryEdit(entry: updated),
            updatedAt: try instant("2026-07-13T11:00:00Z")
        )

        XCTAssertEqual(saved.revision, 0)
        XCTAssertEqual(updated.revision, 1)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertEqual(updated.text, "编辑后正文")
        XCTAssertEqual(updated.photos.map(\.id), [photoA, photoB])
        XCTAssertEqual(updated.photos.map(\.annotationText), ["新批注 A", "新批注 B"])
        XCTAssertEqual(
            updated.voices.map(\.transcriptText),
            ["新转写 A", "新转写 B"]
        )
        XCTAssertEqual(updated.voices.map(\.transcriptionStatus), [.completed, .completed])
        XCTAssertEqual(updated.voices.map(\.transcriptionSource), [.manual, .manual])
        XCTAssertTrue(updated.voices.allSatisfy(\.isTranscriptUserEdited))
        XCTAssertEqual(updated.voices.first?.originalRelativePath, saved.voices.first?.originalRelativePath)
        XCTAssertEqual(updated.voices.last?.targetPhotoID, photoB)
        XCTAssertEqual(noOp, updated)
    }

    func testIncompleteEditSetsAndEmptyTranscriptOnlyVoiceDoNotPartiallyPersist() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let photoID = UUID()
        let voiceID = UUID()
        let createdAt = try instant("2026-07-13T08:00:00Z")
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 13))
        let saved = try await workspace.create(
            NewEntry(
                text: "不可部分修改",
                photos: [
                    makePhoto(
                        id: photoID,
                        annotationText: "原批注",
                        originalRelativePath: "original/atomic.heic",
                        thumbnailRelativePath: "thumbnail/atomic.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: voiceID,
                        originalRelativePath: nil,
                        transcriptText: "原转写",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: createdAt,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )

        do {
            _ = try await workspace.updateEntry(
                id: saved.id,
                userID: userID,
                edit: EntryEdit(
                    expectedRevision: 0,
                    text: "不应保存的新正文",
                    photoAnnotations: [],
                    voiceTranscripts: [
                        EntryVoiceTranscriptEdit(
                            voiceID: voiceID,
                            transcriptText: "新转写",
                            transcriptionStatus: .completed,
                            transcriptionSource: .manual,
                            isTranscriptUserEdited: true,
                            sourceLocaleIdentifier: "zh-CN"
                        )
                    ]
                ),
                updatedAt: createdAt.addingTimeInterval(60)
            )
            XCTFail("缺少完整图片批注集合时不应保存")
        } catch {
            XCTAssertEqual(error as? DayWorkspaceError, .invalidPhotoAnnotationSet)
        }

        do {
            _ = try await workspace.updateEntry(
                id: saved.id,
                userID: userID,
                edit: EntryEdit(
                    expectedRevision: 0,
                    text: "不应保存的新正文",
                    photoAnnotations: [
                        EntryPhotoAnnotationEdit(photoID: photoID, annotationText: "新批注")
                    ],
                    voiceTranscripts: [
                        EntryVoiceTranscriptEdit(
                            voiceID: voiceID,
                            transcriptText: "   ",
                            transcriptionStatus: .completed,
                            transcriptionSource: .manual,
                            isTranscriptUserEdited: true,
                            sourceLocaleIdentifier: "zh-CN"
                        )
                    ]
                ),
                updatedAt: createdAt.addingTimeInterval(120)
            )
            XCTFail("仅转写语音不能为空")
        } catch {
            XCTAssertEqual(
                error as? EntryValidationError,
                .transcriptOnlyVoiceRequiresTranscript
            )
        }

        let reloadedEntries = try await workspace.entries(for: day, userID: userID)
        let reloaded = try XCTUnwrap(reloadedEntries.first)
        XCTAssertEqual(reloaded, saved)
    }

    func testTranscriptOnlyMutationPreservesEntryAndOtherVoiceWhileAdvancingRevision() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let firstVoiceID = UUID()
        let secondVoiceID = UUID()
        let createdAt = try instant("2026-07-13T08:00:00Z")
        let saved = try await workspace.create(
            NewEntry(
                text: "正文不能丢",
                voices: [
                    makeVoice(
                        id: firstVoiceID,
                        originalRelativePath: VoiceAudioStoragePath.relativePath(for: firstVoiceID),
                        transcriptText: "待修改"
                    ),
                    makeVoice(
                        id: secondVoiceID,
                        originalRelativePath: VoiceAudioStoragePath.relativePath(for: secondVoiceID),
                        transcriptText: "保持原样"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: createdAt,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )

        _ = try await workspace.updateVoiceTranscript(
            id: firstVoiceID,
            userID: userID,
            text: "只修改第一段",
            status: .completed,
            source: .manual,
            isUserEdited: true,
            sourceLocaleIdentifier: "zh-CN",
            updatedAt: createdAt.addingTimeInterval(60)
        )
        let reloadedEntries = try await workspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        let reloaded = try XCTUnwrap(reloadedEntries.first)

        let ignoredAutomaticResult = try await workspace.updateVoiceTranscript(
            id: firstVoiceID,
            userID: userID,
            text: "自动转写不得覆盖",
            status: .completed,
            source: .onDevice,
            isUserEdited: false,
            sourceLocaleIdentifier: "zh-CN",
            updatedAt: createdAt.addingTimeInterval(120)
        )
        let afterIgnoredAutomaticEntries = try await workspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        let afterIgnoredAutomatic = try XCTUnwrap(afterIgnoredAutomaticEntries.first)

        let clearedEdit = EntryEdit(
            expectedRevision: afterIgnoredAutomatic.revision,
            text: afterIgnoredAutomatic.text,
            photoAnnotations: [],
            voiceTranscripts: afterIgnoredAutomatic.voices.map { voice in
                EntryVoiceTranscriptEdit(
                    voiceID: voice.id,
                    transcriptText: voice.id == firstVoiceID ? "" : voice.transcriptText,
                    transcriptionStatus: .completed,
                    transcriptionSource: .onDevice,
                    isTranscriptUserEdited: true,
                    sourceLocaleIdentifier: voice.sourceLocaleIdentifier
                )
            }
        )
        let cleared = try await workspace.updateEntry(
            id: saved.id,
            userID: userID,
            edit: clearedEdit,
            updatedAt: createdAt.addingTimeInterval(180)
        )

        XCTAssertEqual(reloaded.revision, 1)
        XCTAssertEqual(reloaded.text, "正文不能丢")
        XCTAssertEqual(reloaded.photos, saved.photos)
        XCTAssertEqual(reloaded.voices.map(\.transcriptText), ["只修改第一段", "保持原样"])
        XCTAssertEqual(reloaded.voices.last, saved.voices.last)
        XCTAssertEqual(ignoredAutomaticResult, reloaded.voices.first)
        XCTAssertEqual(afterIgnoredAutomatic, reloaded)
        XCTAssertEqual(cleared.revision, 2)
        XCTAssertEqual(cleared.voices.first?.transcriptText, "")
        XCTAssertEqual(cleared.voices.first?.transcriptionStatus, .notRequested)
        XCTAssertNil(cleared.voices.first?.transcriptionSource)
        XCTAssertFalse(cleared.voices.first?.isTranscriptUserEdited == true)
        XCTAssertEqual(
            cleared.voices.first?.originalRelativePath,
            saved.voices.first?.originalRelativePath
        )
        XCTAssertEqual(cleared.voices.last, saved.voices.last)
    }

    @MainActor
    func testPhotoAttachmentScopeCorruptionFailsClosedBeforeReadDeleteAndRetention() async throws {
        for corruption in AttachmentScopeCorruption.allCases {
            let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
            let seedWorkspace = SwiftDataDayWorkspace(modelContainer: container)
            let photoID = UUID()
            let saved = try await seedWorkspace.create(
                NewEntry(
                    text: "图片范围损坏测试",
                    photos: [
                        makePhoto(
                            id: photoID,
                            originalRelativePath: "original/photo-scope.heic",
                            thumbnailRelativePath: "thumbnail/photo-scope.jpg"
                        )
                    ]
                ),
                userID: userID,
                context: RecordingContext(
                    instant: try instant("2026-07-13T08:00:00Z"),
                    timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
                )
            )
            let context = ModelContext(container)
            let photoRecord = try XCTUnwrap(
                try context.fetch(FetchDescriptor<PhotoAttachmentRecord>()).first
            )
            switch corruption {
            case .entryID:
                photoRecord.entryID = UUID()
            case .userID:
                photoRecord.userID = UUID()
            case .dayKey:
                photoRecord.dayKeyRawValue = 20_260_714
            }
            try context.save()

            let workspace = SwiftDataDayWorkspace(modelContainer: container)
            do {
                _ = try await workspace.entries(for: saved.dayKey, userID: userID)
                XCTFail("\(corruption) 损坏后不应读取图片附件")
            } catch let PersistenceMappingError.invalidPhotoAttachmentScope(id) {
                XCTAssertEqual(id, photoID)
            }

            do {
                _ = try await workspace.deleteEntry(
                    id: saved.id,
                    userID: userID,
                    expectedRevision: saved.revision,
                    deletedAt: saved.createdAt.addingTimeInterval(60)
                )
                XCTFail("\(corruption) 损坏后不应删除主记录")
            } catch let PersistenceMappingError.invalidPhotoAttachmentScope(id) {
                XCTAssertEqual(id, photoID)
            }

            do {
                _ = try await workspace.photoIDs(userID: userID)
                XCTFail("\(corruption) 损坏后不应返回不可信的媒体保留集合")
            } catch let PersistenceMappingError.invalidPhotoAttachmentScope(id) {
                XCTAssertEqual(id, photoID)
            }

            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<EntryRecord>()),
                1
            )
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<PhotoAttachmentRecord>()),
                1
            )
        }
    }

    @MainActor
    func testVoiceAttachmentScopeAndTargetOwnerCorruptionFailClosed() async throws {
        for corruption in VoiceAttachmentCorruption.allCases {
            let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
            let seedWorkspace = SwiftDataDayWorkspace(modelContainer: container)
            let sourcePhotoID = UUID()
            let otherPhotoID = UUID()
            let voiceID = UUID()
            let recordingContext = RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
            let saved = try await seedWorkspace.create(
                NewEntry(
                    text: "语音范围损坏测试",
                    photos: [
                        makePhoto(
                            id: sourcePhotoID,
                            originalRelativePath: "original/voice-owner.heic",
                            thumbnailRelativePath: "thumbnail/voice-owner.jpg"
                        )
                    ],
                    voices: [
                        makeVoice(
                            id: voiceID,
                            targetPhotoID: sourcePhotoID,
                            originalRelativePath: VoiceAudioStoragePath.relativePath(for: voiceID)
                        )
                    ]
                ),
                userID: userID,
                context: recordingContext
            )
            _ = try await seedWorkspace.create(
                NewEntry(
                    text: "另一条记录",
                    photos: [
                        makePhoto(
                            id: otherPhotoID,
                            originalRelativePath: "original/other-owner.heic",
                            thumbnailRelativePath: "thumbnail/other-owner.jpg"
                        )
                    ]
                ),
                userID: userID,
                context: recordingContext
            )

            let context = ModelContext(container)
            let voiceRecord = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<VoiceAttachmentRecord>(
                        predicate: #Predicate<VoiceAttachmentRecord> { record in
                            record.id == voiceID
                        }
                    )
                ).first
            )
            switch corruption {
            case .entryID:
                voiceRecord.entryID = UUID()
            case .userID:
                voiceRecord.userID = UUID()
            case .dayKey:
                voiceRecord.dayKeyRawValue = 20_260_714
            case .targetPhotoOwner:
                voiceRecord.targetPhotoID = otherPhotoID
            }
            try context.save()

            let workspace = SwiftDataDayWorkspace(modelContainer: container)
            do {
                _ = try await workspace.entries(for: saved.dayKey, userID: userID)
                XCTFail("\(corruption) 损坏后不应读取语音附件")
            } catch {
                assertVoiceCorruptionError(
                    error,
                    voiceID: voiceID,
                    expectsTargetError: corruption == .targetPhotoOwner
                )
            }

            do {
                _ = try await workspace.deleteEntry(
                    id: saved.id,
                    userID: userID,
                    expectedRevision: saved.revision,
                    deletedAt: saved.createdAt.addingTimeInterval(60)
                )
                XCTFail("\(corruption) 损坏后不应删除主记录")
            } catch {
                assertVoiceCorruptionError(
                    error,
                    voiceID: voiceID,
                    expectsTargetError: corruption == .targetPhotoOwner
                )
            }

            do {
                _ = try await workspace.retainedVoiceIDs(userID: userID)
                XCTFail("\(corruption) 损坏后不应返回不可信的音频保留集合")
            } catch {
                assertVoiceCorruptionError(
                    error,
                    voiceID: voiceID,
                    expectsTargetError: corruption == .targetPhotoOwner
                )
            }

            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<EntryRecord>()),
                2
            )
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<VoiceAttachmentRecord>()),
                1
            )
        }
    }

    @MainActor
    func testConcurrentEditAndDeleteWithSameRevisionAllowsOnlyOneMutation() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let seedWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let editWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let deleteWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let createdAt = try instant("2026-07-13T08:00:00Z")
        let saved = try await seedWorkspace.create(
            NewEntry(text: "并发前"),
            userID: userID,
            context: RecordingContext(
                instant: createdAt,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )
        let edit = EntryEdit(
            expectedRevision: saved.revision,
            text: "并发编辑成功",
            photoAnnotations: [],
            voiceTranscripts: []
        )
        let requestedUserID = userID

        async let edited: Entry? = try? await editWorkspace.updateEntry(
            id: saved.id,
            userID: requestedUserID,
            edit: edit,
            updatedAt: createdAt.addingTimeInterval(60)
        )
        async let deleted: Entry? = try? await deleteWorkspace.deleteEntry(
            id: saved.id,
            userID: requestedUserID,
            expectedRevision: saved.revision,
            deletedAt: createdAt.addingTimeInterval(60)
        )
        let (editedResult, deletedResult) = await (edited, deleted)
        let successes = [editedResult, deletedResult].compactMap { $0 }
        let remaining = try await seedWorkspace.entries(for: saved.dayKey, userID: userID)

        XCTAssertEqual(successes.count, 1)
        if let remainingEntry = remaining.first {
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remainingEntry.text, "并发编辑成功")
            XCTAssertEqual(remainingEntry.revision, 1)
        } else {
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertEqual(successes.first, saved)
        }
    }

    @MainActor
    func testDeleteReturnsSnapshotRemovesDatabaseRowsAndRetainsJournalPhoto() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let dayWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        let photoID = UUID()
        let voiceID = UUID()
        let saved = try await dayWorkspace.create(
            NewEntry(
                text: "即将删除",
                photos: [
                    makePhoto(
                        id: photoID,
                        annotationText: "会进入日记",
                        originalRelativePath: "original/journal-retained.heic",
                        thumbnailRelativePath: "thumbnail/journal-retained.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: voiceID,
                        originalRelativePath: VoiceAudioStoragePath.relativePath(for: voiceID)
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )
        let firstJournal = try await journalWorkspace.append(
            NewJournalVersion(
                title: "保留历史照片",
                blocks: [JournalBlock(photo: try XCTUnwrap(saved.photos.first))],
                origin: .generated,
                sourceFingerprint: try JournalSourceFingerprint.make(entries: [saved]),
                sourceEntryCount: 1,
                createdAt: saved.createdAt.addingTimeInterval(60)
            ),
            for: saved.dayKey,
            userID: userID
        )

        let snapshot = try await dayWorkspace.deleteEntry(
            id: saved.id,
            userID: userID,
            expectedRevision: saved.revision,
            deletedAt: saved.createdAt.addingTimeInterval(120)
        )
        let restoredJournal = try await journalWorkspace.append(
            NewJournalVersion(
                title: "删除记录后仍可恢复历史照片",
                blocks: [JournalBlock(photo: try XCTUnwrap(snapshot.photos.first))],
                origin: .restored,
                sourceFingerprint: JournalSourceFingerprint(
                    rawValue: String(repeating: "a", count: 64)
                ),
                sourceEntryCount: 1,
                baseVersionID: firstJournal.currentVersion.id,
                createdAt: saved.createdAt.addingTimeInterval(180)
            ),
            for: saved.dayKey,
            userID: userID
        )
        let retainedPhotoIDs = try await dayWorkspace.photoIDs(userID: userID)
        let retainedVoiceIDs = try await dayWorkspace.retainedVoiceIDs(userID: userID)
        let remainingEntries = try await dayWorkspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        let context = ModelContext(container)

        XCTAssertEqual(snapshot, saved)
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertEqual(retainedPhotoIDs, [photoID])
        XCTAssertTrue(retainedVoiceIDs.isEmpty)
        XCTAssertEqual(restoredJournal.currentVersion.versionNumber, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EntryRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoAttachmentRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceAttachmentRecord>()), 0)
    }

    func testGeneratedAppendRevalidatesTextAndVoiceSourcesAfterDeletion() async throws {
        let voiceID = UUID()
        let scenarios: [(name: String, draft: NewEntry)] = [
            ("纯文字", try NewEntry(text: "删除前的纯文字素材")),
            (
                "纯语音",
                try NewEntry(
                    text: "",
                    voices: [
                        makeVoice(
                            id: voiceID,
                            originalRelativePath: nil,
                            transcriptText: "删除前的纯语音转写",
                            transcriptionStatus: .completed
                        )
                    ]
                )
            ),
        ]

        for scenario in scenarios {
            let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
            let dayWorkspace = SwiftDataDayWorkspace(modelContainer: container)
            let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
            let saved = try await dayWorkspace.create(
                scenario.draft,
                userID: userID,
                context: RecordingContext(
                    instant: try instant("2026-07-13T08:00:00Z"),
                    timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
                )
            )
            let generatedText = saved.text.isEmpty
                ? try XCTUnwrap(saved.voices.first?.transcriptText)
                : saved.text
            let draft = NewJournalVersion(
                title: "并发生成",
                blocks: [JournalBlock(text: generatedText)],
                origin: .generated,
                sourceFingerprint: try JournalSourceFingerprint.make(entries: [saved]),
                sourceEntryCount: 1,
                createdAt: saved.createdAt.addingTimeInterval(60)
            )
            let gate = PersistenceTestGate()
            let requestedUserID = userID
            let appendTask = Task {
                await gate.wait()
                do {
                    _ = try await journalWorkspace.append(
                        draft,
                        for: saved.dayKey,
                        userID: requestedUserID
                    )
                    return GatedJournalAppendOutcome.saved
                } catch JournalPersistenceError.sourceMaterialChanged {
                    return GatedJournalAppendOutcome.sourceMaterialChanged
                } catch {
                    return GatedJournalAppendOutcome.unexpected(
                        String(reflecting: error)
                    )
                }
            }

            await gate.waitUntilBlocked()
            _ = try await dayWorkspace.deleteEntry(
                id: saved.id,
                userID: userID,
                expectedRevision: saved.revision,
                deletedAt: saved.createdAt.addingTimeInterval(60)
            )
            await gate.open()

            let appendOutcome = await appendTask.value
            XCTAssertEqual(appendOutcome, .sourceMaterialChanged, scenario.name)
            let journal = try await journalWorkspace.journal(
                for: saved.dayKey,
                userID: userID
            )
            XCTAssertNil(journal, scenario.name)
        }
    }

    func testDeletedPhotoCannotBecomeFirstJournalReference() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let dayWorkspace = SwiftDataDayWorkspace(modelContainer: container)
        let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
        let photoID = UUID()
        let saved = try await dayWorkspace.create(
            NewEntry(
                text: "删除先发生",
                photos: [
                    makePhoto(
                        id: photoID,
                        originalRelativePath: "original/deleted-first.heic",
                        thumbnailRelativePath: "thumbnail/deleted-first.jpg"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )
        _ = try await dayWorkspace.deleteEntry(
            id: saved.id,
            userID: userID,
            expectedRevision: saved.revision,
            deletedAt: saved.createdAt.addingTimeInterval(60)
        )

        do {
            _ = try await journalWorkspace.append(
                NewJournalVersion(
                    title: "不应保存",
                    blocks: [JournalBlock(photo: try XCTUnwrap(saved.photos.first))],
                    origin: .edited,
                    sourceFingerprint: JournalSourceFingerprint(
                        rawValue: String(repeating: "c", count: 64)
                    ),
                    sourceEntryCount: 1,
                    createdAt: saved.createdAt.addingTimeInterval(120)
                ),
                for: saved.dayKey,
                userID: userID
            )
            XCTFail("已删除且从未进入日记历史的照片不应建立首个引用")
        } catch {
            XCTAssertEqual(
                error as? JournalPersistenceError,
                .unavailablePhotoReference(photoID)
            )
        }
        let journal = try await journalWorkspace.journal(
            for: saved.dayKey,
            userID: userID
        )
        let retainedPhotoIDs = try await dayWorkspace.photoIDs(userID: userID)
        XCTAssertNil(journal)
        XCTAssertTrue(retainedPhotoIDs.isEmpty)
    }

    func testSearchNormalizesUnicodeWhitespaceUsesAndAcrossFieldsAndIsUserIsolated() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T08:00:00Z")
        let context = RecordingContext(instant: createdAt, timeZone: shanghai)
        let firstVoiceID = UUID()
        let secondVoiceID = UUID()
        let first = try await workspace.create(
            NewEntry(
                text: "Café　ＭＯＲＮＩＮＧ",
                photos: [
                    makePhoto(
                        annotationText: "海边 日落",
                        originalRelativePath: "original/search-a.heic",
                        thumbnailRelativePath: "thumbnail/search-a.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: firstVoiceID,
                        originalRelativePath: nil,
                        transcriptText: "晚 风",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: context
        )
        let second = try await workspace.create(
            NewEntry(
                text: "CAFE morning",
                photos: [
                    makePhoto(
                        annotationText: "海边",
                        originalRelativePath: "original/search-b.heic",
                        thumbnailRelativePath: "thumbnail/search-b.jpg"
                    )
                ],
                voices: [
                    makeVoice(
                        id: secondVoiceID,
                        originalRelativePath: nil,
                        transcriptText: "风",
                        transcriptionStatus: .completed
                    )
                ]
            ),
            userID: userID,
            context: context
        )
        _ = try await workspace.create(
            NewEntry(text: "cafe 但没有另一个词"),
            userID: userID,
            context: context
        )
        _ = try await workspace.create(
            NewEntry(text: "CAFE MORNING 海边 风"),
            userID: UUID(),
            context: context
        )

        let folded = try await workspace.searchEntries(
            matching: "  cafe\nＭＯＲＮＩＮＧ  ",
            userID: userID
        )
        let acrossFields = try await workspace.searchEntries(
            matching: "海边\t风",
            userID: userID
        )
        let expectedIDs = [first.id, second.id].sorted {
            $0.uuidString > $1.uuidString
        }
        let emptyResults = try await workspace.searchEntries(
            matching: "   ",
            userID: userID
        )
        let missingTermResults = try await workspace.searchEntries(
            matching: "海边 不存在",
            userID: userID
        )

        XCTAssertEqual(folded.map(\.id), expectedIDs)
        XCTAssertEqual(acrossFields.map(\.id), expectedIDs)
        XCTAssertTrue(emptyResults.isEmpty)
        XCTAssertTrue(missingTermResults.isEmpty)
    }

    func testEntryMutationsTreatAnotherUsersEntryAsNotFound() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let saved = try await workspace.create(
            NewEntry(text: "只属于当前用户"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            )
        )
        let otherUserID = UUID()

        do {
            _ = try await workspace.updateEntry(
                id: saved.id,
                userID: otherUserID,
                edit: EntryEdit(
                    expectedRevision: saved.revision,
                    text: "越权修改",
                    photoAnnotations: [],
                    voiceTranscripts: []
                ),
                updatedAt: saved.updatedAt.addingTimeInterval(60)
            )
            XCTFail("其他用户不应能修改记录")
        } catch {
            XCTAssertEqual(error as? DayWorkspaceError, .entryNotFound)
        }

        do {
            _ = try await workspace.deleteEntry(
                id: saved.id,
                userID: otherUserID,
                expectedRevision: saved.revision,
                deletedAt: saved.updatedAt.addingTimeInterval(60)
            )
            XCTFail("其他用户不应能删除记录")
        } catch {
            XCTAssertEqual(error as? DayWorkspaceError, .entryNotFound)
        }

        let reloadedEntries = try await workspace.entries(
            for: saved.dayKey,
            userID: userID
        )
        XCTAssertEqual(reloadedEntries, [saved])
    }

    private func assertVoiceCorruptionError(
        _ error: Error,
        voiceID: UUID,
        expectsTargetError: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if expectsTargetError {
            guard case let PersistenceMappingError.invalidVoiceTargetPhoto(id) = error else {
                XCTFail("预期语音目标图片范围错误，实际为 \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(id, voiceID, file: file, line: line)
        } else {
            guard case let PersistenceMappingError.invalidVoiceAttachmentScope(id) = error else {
                XCTFail("预期语音附件范围错误，实际为 \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(id, voiceID, file: file, line: line)
        }
    }

    private func writePersistentEntry(
        storeURL: URL,
        draft: NewEntry,
        createdAt: Date,
        timeZone: TimeZone
    ) async throws {
        let container = try ModelContainerFactory.make(
            configurationName: "PersistenceRestart",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        _ = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: timeZone)
        )
    }

    private func writeLegacyEntry(
        storeURL: URL,
        text: String,
        createdAt: Date,
        timeZone: TimeZone
    ) throws {
        let schema = Schema(versionedSchema: LegacyEntrySchemaV1.self)
        let configuration = ModelConfiguration(
            "LegacyMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let day = DayKey(containing: createdAt, in: timeZone)
        context.insert(
            LegacyEntrySchemaV1.EntryRecord(
                id: UUID(),
                userID: userID,
                dayKeyRawValue: day.storageValue,
                createdAt: createdAt,
                updatedAt: createdAt,
                creationTimeZoneIdentifier: timeZone.identifier,
                text: text
            )
        )
        try context.save()
    }

    private func makePhoto(
        id: UUID = UUID(),
        annotationText: String = "",
        originalRelativePath: String,
        thumbnailRelativePath: String
    ) -> NewPhotoAttachment {
        NewPhotoAttachment(
            id: id,
            annotationText: annotationText,
            contentTypeIdentifier: "public.heic",
            pixelWidth: 3024,
            pixelHeight: 4032,
            byteCount: 2_048,
            originalRelativePath: originalRelativePath,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }

    private func makeVoice(
        id: UUID = UUID(),
        targetPhotoID: UUID? = nil,
        originalRelativePath: String?,
        transcriptText: String = "",
        transcriptionStatus: VoiceTranscriptionStatus = .notRequested,
        transcriptionSource: VoiceTranscriptionSource? = nil,
        isTranscriptUserEdited: Bool = false,
        sourceLocaleIdentifier: String = ""
    ) -> NewVoiceAttachment {
        NewVoiceAttachment(
            id: id,
            targetPhotoID: targetPhotoID,
            durationMilliseconds: 12_345,
            contentTypeIdentifier: originalRelativePath == nil ? nil : "public.mpeg-4-audio",
            byteCount: originalRelativePath == nil ? 0 : 4_096,
            originalRelativePath: originalRelativePath,
            transcriptText: transcriptText,
            transcriptionStatus: transcriptionStatus,
            transcriptionSource: transcriptionSource,
            sourceLocaleIdentifier: sourceLocaleIdentifier,
            isTranscriptUserEdited: isTranscriptUserEdited
        )
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeNotesTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private enum GatedJournalAppendOutcome: Equatable, Sendable {
    case saved
    case sourceMaterialChanged
    case unexpected(String)
}

private enum AttachmentScopeCorruption: CaseIterable {
    case entryID
    case userID
    case dayKey
}

private enum VoiceAttachmentCorruption: CaseIterable {
    case entryID
    case userID
    case dayKey
    case targetPhotoOwner
}

private actor PersistenceTestGate {
    private var isBlocked = false
    private var isOpen = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isBlocked = true
        let arrivals = blockedWaiters
        blockedWaiters.removeAll()
        for continuation in arrivals {
            continuation.resume()
        }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
}

private enum LegacyEntrySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [EntryRecord.self]
    }

    @Model
    final class EntryRecord {
        @Attribute(.unique) var id: UUID
        var userID: UUID
        var sourceDraftID: UUID? = nil
        var dayKeyRawValue: Int
        var createdAt: Date
        var updatedAt: Date
        var creationTimeZoneIdentifier: String
        var text: String

        init(
            id: UUID,
            userID: UUID,
            sourceDraftID: UUID? = nil,
            dayKeyRawValue: Int,
            createdAt: Date,
            updatedAt: Date,
            creationTimeZoneIdentifier: String,
            text: String
        ) {
            self.id = id
            self.userID = userID
            self.sourceDraftID = sourceDraftID
            self.dayKeyRawValue = dayKeyRawValue
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
            self.text = text
        }
    }
}
