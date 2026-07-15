import SwiftData
import SwiftUI

@main
@MainActor
struct LifeNotesApp: App {
    private static let writingStyleDefaultsKey = "journal.writing-style"

    private let modelContainer: ModelContainer
    @StateObject private var appModel: AppModel
    @StateObject private var calendarModel: CalendarModel
    @StateObject private var journalModel: JournalModel
    @StateObject private var entryLibraryModel: EntryLibraryModel

    init() {
        do {
            let container = try ModelContainerFactory.make()
            let workspace = SwiftDataDayWorkspace(modelContainer: container)
            let journalWorkspace = SwiftDataJournalWorkspace(modelContainer: container)
            let photoLibrary = try FilePhotoLibrary.makeDefault()
            let audioLibrary = try FileAudioLibrary.makeDefault()
            let captureDraftStore = try FileCaptureDraftStore.makeDefault()
            let voiceRecorder = SystemVoiceRecorder()
            let speechTranscriber = SystemSpeechTranscriber()
            let voicePlayer = SystemVoicePlayer()
            let userID = LocalUserIdentity.loadOrCreate()
            let writingStyle = UserDefaults.standard
                .string(forKey: Self.writingStyleDefaultsKey)
                .flatMap(WritingStyle.init(rawValue:)) ?? .natural

            modelContainer = container
            _appModel = StateObject(
                wrappedValue: AppModel(
                    workspace: workspace,
                    photoLibrary: photoLibrary,
                    audioLibrary: audioLibrary,
                    captureDraftStore: captureDraftStore,
                    voiceRecorder: voiceRecorder,
                    speechTranscriber: speechTranscriber,
                    voicePlayer: voicePlayer,
                    userID: userID
                )
            )
            _calendarModel = StateObject(
                wrappedValue: CalendarModel(
                    workspace: workspace,
                    userID: userID
                )
            )
            _journalModel = StateObject(
                wrappedValue: JournalModel(
                    dayWorkspace: workspace,
                    journalWorkspace: journalWorkspace,
                    generator: LocalJournalGenerator(),
                    userID: userID,
                    writingStyle: writingStyle,
                    onWritingStyleChange: { style in
                        UserDefaults.standard.set(
                            style.rawValue,
                            forKey: Self.writingStyleDefaultsKey
                        )
                    }
                )
            )
            _entryLibraryModel = StateObject(
                wrappedValue: EntryLibraryModel(
                    workspace: workspace,
                    userID: userID,
                    photoLibrary: photoLibrary,
                    audioLibrary: audioLibrary
                )
            )
        } catch {
            fatalError("无法初始化本地数据：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                appModel: appModel,
                calendarModel: calendarModel,
                journalModel: journalModel,
                entryLibraryModel: entryLibraryModel
            )
        }
        .modelContainer(modelContainer)
    }
}
