import SwiftData
import SwiftUI

@main
@MainActor
struct LifeNotesApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var appModel: AppModel

    init() {
        do {
            let container = try ModelContainerFactory.make()
            let workspace = SwiftDataDayWorkspace(modelContainer: container)
            let photoLibrary = try FilePhotoLibrary.makeDefault()
            let captureDraftStore = try FileCaptureDraftStore.makeDefault()
            let userID = LocalUserIdentity.loadOrCreate()

            modelContainer = container
            _appModel = StateObject(
                wrappedValue: AppModel(
                    workspace: workspace,
                    photoLibrary: photoLibrary,
                    captureDraftStore: captureDraftStore,
                    userID: userID
                )
            )
        } catch {
            fatalError("无法初始化本地数据：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(appModel: appModel)
        }
        .modelContainer(modelContainer)
    }
}
