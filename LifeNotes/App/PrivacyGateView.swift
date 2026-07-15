import SwiftUI

struct PrivacyGateView: View {
    @ObservedObject var model: PrivacyGateModel

    var body: some View {
        ZStack {
            AppTheme.paper.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(AppTheme.accent, AppTheme.accentSoft)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("随心记")
                        .font(.largeTitle.bold())
                        .foregroundStyle(AppTheme.ink)
                        .accessibilityAddTraits(.isHeader)

                    Text("你的记录只留给你")
                        .font(.body)
                        .foregroundStyle(AppTheme.mutedInk)
                }

                if let message = stateMessage {
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(maxWidth: 320)
                }

                Button {
                    Task { await model.unlock() }
                } label: {
                    HStack(spacing: 10) {
                        if model.state == .authenticating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "faceid")
                                .accessibilityHidden(true)
                        }
                        Text(buttonTitle)
                    }
                    .font(.headline)
                    .frame(maxWidth: 300, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 12))
                .disabled(model.state == .authenticating)
                .accessibilityLabel("解锁随心记")

                Spacer()
            }
            .padding(24)
        }
    }

    private var buttonTitle: String {
        model.state == .authenticating ? "正在验证" : "解锁随心记"
    }

    private var stateMessage: String? {
        switch model.state {
        case let .unavailable(message), let .failed(message):
            return message
        default:
            return nil
        }
    }
}

private struct PrivacyProtectedPresentationModifier: ViewModifier {
    @EnvironmentObject private var privacyGate: PrivacyGateModel

    func body(content: Content) -> some View {
        ZStack {
            content
                .privacySensitive()
                .allowsHitTesting(!privacyGate.isContentCovered)
                .accessibilityHidden(privacyGate.isContentCovered)

            if privacyGate.isContentCovered {
                PrivacyGateView(model: privacyGate)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: privacyGate.isContentCovered)
    }
}

extension View {
    func privacyProtectedPresentation() -> some View {
        modifier(PrivacyProtectedPresentationModifier())
    }
}
