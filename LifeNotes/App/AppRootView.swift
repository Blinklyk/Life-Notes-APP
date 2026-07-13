import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel
    @StateObject private var privacyGate = PrivacyGateModel()

    var body: some View {
        Group {
            if privacyGate.state == .unlocked, scenePhase == .active {
                content
                    .privacySensitive()
            } else {
                PrivacyGateView(model: privacyGate)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: privacyGate.state)
        .onChange(of: privacyGate.state) { _, newState in
            if newState == .unlocked {
                appModel.showCapture()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                privacyGate.lock()
            } else if newPhase == .active {
                Task { await privacyGate.unlock() }
            }
        }
        .task {
            if scenePhase == .active {
                await privacyGate.unlock()
            }
        }
        .alert(item: $appModel.alert) { alert in
            Alert(
                title: Text("随心记"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.route {
        case .capture:
            CaptureView(appModel: appModel)
        case .today:
            TodayView(appModel: appModel)
        }
    }
}
