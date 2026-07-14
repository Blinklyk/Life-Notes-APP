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
    func testRetainedVoiceIDsProtectBothRecordAndPathIDsWhenMismatched() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let recordID = UUID()
        let pathID = UUID()
        let context = ModelContext(container)
        context.insert(
            VoiceAttachmentRecord(
                id: recordID,
                entryID: UUID(),
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

        let retainedIDs = try await workspace.allRetainedVoiceIDs()

        XCTAssertEqual(retainedIDs, [recordID, pathID])
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

        XCTAssertEqual(entries.map(\.text), ["旧版本的文字记录"])
        XCTAssertTrue(entries.first?.photos.isEmpty == true)
        XCTAssertTrue(entries.first?.voices.isEmpty == true)
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
        let schema = Schema([EntryRecord.self])
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
            EntryRecord(
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
