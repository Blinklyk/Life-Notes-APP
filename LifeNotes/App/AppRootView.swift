import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var journalModel: JournalModel
    @StateObject private var privacyGate = PrivacyGateModel()
    @State private var hasCompletedInitialUnlock = false

    var body: some View {
        ZStack {
            content
                .privacySensitive()
                .allowsHitTesting(!shouldCoverContent)
                .accessibilityHidden(shouldCoverContent)

            if shouldCoverContent {
                PrivacyGateView(model: privacyGate)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldCoverContent)
        .onChange(of: privacyGate.state) { _, newState in
            if newState == .unlocked, !hasCompletedInitialUnlock {
                hasCompletedInitialUnlock = true
                appModel.showCapture()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                appModel.handleSceneDeactivation(
                    isEnteringBackground: newPhase == .background
                )
            }
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

    private var shouldCoverContent: Bool {
        privacyGate.state != .unlocked || scenePhase != .active
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.route {
        case .capture:
            CaptureView(appModel: appModel)
        case .today:
            TodayView(
                appModel: appModel,
                journalModel: journalModel
            )
        case .calendar:
            CalendarView(
                appModel: appModel,
                calendarModel: calendarModel,
                journalModel: journalModel
            )
        }
    }
}
