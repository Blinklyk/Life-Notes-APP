import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var journalModel: JournalModel
    @ObservedObject var entryLibraryModel: EntryLibraryModel
    @ObservedObject var backendSettingsModel: BackendSettingsModel
    @StateObject private var privacyGate = PrivacyGateModel()
    @State private var hasCompletedInitialUnlock = false
    @State private var showsBackendSettings = false

    var body: some View {
        ZStack {
            content
                .privacySensitive()
                .allowsHitTesting(!shouldCoverContent)
                .accessibilityHidden(shouldCoverContent)
                .alert(item: $entryLibraryModel.alert) { alert in
                    Alert(
                        title: Text("随心记"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("好"))
                    )
                }

            if shouldCoverContent {
                PrivacyGateView(model: privacyGate)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .environmentObject(privacyGate)
        .animation(.easeInOut(duration: 0.2), value: shouldCoverContent)
        .onChange(of: privacyGate.state) { _, newState in
            if newState == .unlocked, !hasCompletedInitialUnlock {
                hasCompletedInitialUnlock = true
                appModel.showCapture()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            privacyGate.setSceneActive(newPhase == .active)
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
            privacyGate.setSceneActive(scenePhase == .active)
            if scenePhase == .active {
                await privacyGate.unlock()
            }
        }
        .onChange(of: entryLibraryModel.mutationEvent) { _, event in
            guard let event else {
                return
            }
            Task {
                await refreshAfterEntryMutation(event)
            }
        }
        .alert(item: $appModel.alert) { alert in
            Alert(
                title: Text("随心记"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(isPresented: $showsBackendSettings) {
            BackendSettingsView(model: backendSettingsModel)
        }
    }

    private var shouldCoverContent: Bool {
        privacyGate.isContentCovered
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.route {
        case .capture:
            CaptureView(
                appModel: appModel,
                onShowBackendSettings: { showsBackendSettings = true }
            )
        case .today:
            TodayView(
                appModel: appModel,
                journalModel: journalModel,
                entryLibraryModel: entryLibraryModel,
                onShowBackendSettings: { showsBackendSettings = true }
            )
        case .calendar:
            CalendarView(
                appModel: appModel,
                calendarModel: calendarModel,
                journalModel: journalModel,
                entryLibraryModel: entryLibraryModel,
                onShowBackendSettings: { showsBackendSettings = true }
            )
        }
    }

    private func refreshAfterEntryMutation(
        _ event: EntryLibraryModel.MutationEvent
    ) async {
        await appModel.refreshToday(showError: false)
        await calendarModel.loadMonth(showError: false)

        if calendarModel.detail?.dayKey == event.dayKey {
            await calendarModel.loadDetail(for: event.dayKey, showError: false)
        }
        if journalModel.selectedDay == event.dayKey {
            await journalModel.load(day: event.dayKey, showError: false)
        }
    }
}
