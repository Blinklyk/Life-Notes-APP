import SwiftData
import SwiftUI

@main
@MainActor
struct LifeNotesApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var appModel: AppModel
    @StateObject private var calendarModel: CalendarModel

    init() {
        do {
            let container = try ModelContainerFactory.make()
            let workspace = SwiftDataDayWorkspace(modelContainer: container)
            let photoLibrary = try FilePhotoLibrary.makeDefault()
            let audioLibrary = try FileAudioLibrary.makeDefault()
            let captureDraftStore = try FileCaptureDraftStore.makeDefault()
            let voiceRecorder = SystemVoiceRecorder()
            let speechTranscriber = SystemSpeechTranscriber()
            let voicePlayer = SystemVoicePlayer()
            let userID = LocalUserIdentity.loadOrCreate()

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
        } catch {
            fatalError("无法初始化本地数据：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                appModel: appModel,
                calendarModel: calendarModel
            )
        }
        .modelContainer(modelContainer)
    }
}
