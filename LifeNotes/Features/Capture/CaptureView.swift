import SwiftUI
import UIKit

struct CaptureView: View {
    @ObservedObject var appModel: AppModel
    @FocusState private var isEditorFocused: Bool
    @ScaledMetric(relativeTo: .body) private var editorMinimumHeight: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CaptureHeader(onShowToday: { appModel.showToday() })

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(
                        AppDateFormatting.captureTimestamp(
                            context.date,
                            timeZone: .autoupdatingCurrent
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
                    .padding(.top, 36)
                }

                Text("现在，想记下什么？")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.ink)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)

                TextField(
                    "随心记录正文",
                    text: $appModel.draftText,
                    prompt: Text("不用整理好，想到哪里就写到哪里……")
                        .foregroundColor(AppTheme.mutedInk.opacity(0.72)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(7)
                .lineLimit(7...18)
                .focused($isEditorFocused)
                .frame(minHeight: editorMinimumHeight, alignment: .topLeading)
                .padding(.top, 24)
                .accessibilityLabel("随心记录正文")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SaveEntryButton(
                isEnabled: appModel.canSaveDraft,
                isSaving: appModel.isSaving
            ) {
                isEditorFocused = false
                Task {
                    if await appModel.saveDraft() {
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "已保存到今天"
                        )
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isEditorFocused = true
        }
    }
}

private struct CaptureHeader: View {
    let onShowToday: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                brand
                Spacer(minLength: 12)
                todayButton
            }

            VStack(alignment: .leading, spacing: 8) {
                brand
                todayButton
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Text("心")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            Text("随心记")
                .font(.headline.bold())
                .foregroundStyle(AppTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("随心记")
    }

    private var todayButton: some View {
        Button(action: onShowToday) {
            HStack(spacing: 5) {
                Text("查看今天")
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.mutedInk)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看今天")
    }
}

private struct SaveEntryButton: View {
    let isEnabled: Bool
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.divider)

            Button(action: action) {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isSaving ? "正在保存" : "记下这一刻")
                    if !isSaving {
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                isEnabled ? AppTheme.ink : AppTheme.mutedInk.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(!isEnabled)
            .accessibilityLabel(isSaving ? "正在保存" : "记下这一刻")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }
}
