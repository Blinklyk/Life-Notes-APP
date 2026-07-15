import SwiftUI

struct DayStateEditor: View {
    let dayState: DayState
    let isSaving: Bool
    let onSetFeeling: @MainActor (DailyFeeling?) async -> Void
    let onSetImportant: @MainActor (Bool) async -> Void

    @State private var isFeelingPickerPresented = false
    @State private var isSettingFeeling = false
    @State private var isSettingImportant = false
    @State private var pendingImportantValue: Bool?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                feelingButton(expands: false)
                importantToggle(expands: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                feelingButton(expands: true)
                importantToggle(expands: true)
            }
        }
        .sheet(isPresented: $isFeelingPickerPresented) {
            feelingPicker
        }
    }

    private var feelingPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(
                        DailyFeeling.allCases.sorted { $0.level < $1.level },
                        id: \.self
                    ) { feeling in
                        Button {
                            setFeeling(feeling)
                        } label: {
                            HStack(spacing: 12) {
                                FeelingFlower(level: feeling.level)

                                Text(feeling.label)
                                    .font(.body)
                                    .foregroundStyle(AppTheme.ink)

                                Spacer(minLength: 12)

                                Text("\(feeling.level) / 5")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppTheme.mutedInk)

                                if dayState.feeling == feeling {
                                    Image(systemName: "checkmark")
                                        .font(.callout.bold())
                                        .foregroundStyle(AppTheme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            isFeelingControlDisabled || dayState.feeling == feeling
                        )
                        .accessibilityLabel(
                            "\(feeling.label)，第 \(feeling.level) 级，共 5 级"
                        )
                        .accessibilityAddTraits(
                            dayState.feeling == feeling ? .isSelected : []
                        )
                    }
                } header: {
                    Text("选择这一天的总体感受")
                }

                Section {
                    Button {
                        setFeeling(nil)
                    } label: {
                        Label("清除每日感受", systemImage: "xmark.circle")
                            .font(.body)
                            .foregroundStyle(AppTheme.mutedInk)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(dayState.feeling == nil || isFeelingControlDisabled)
                    .accessibilityLabel("清除每日感受")
                    .accessibilityHint("恢复为未设置")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.paper)
            .navigationTitle("每日感受")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        isFeelingPickerPresented = false
                    }
                    .disabled(isSettingFeeling)
                }

                if isSettingFeeling {
                    ToolbarItem(placement: .confirmationAction) {
                        ProgressView()
                            .accessibilityLabel("正在保存每日感受")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSettingFeeling)
        .privacyProtectedPresentation()
    }

    private func feelingButton(expands: Bool) -> some View {
        Button {
            isFeelingPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                FeelingFlower(level: dayState.feeling?.level ?? 0)

                Text(feelingButtonTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        dayState.feeling == nil ? AppTheme.mutedInk : AppTheme.accent
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if isSettingFeeling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(
                maxWidth: expands ? .infinity : nil,
                minHeight: 44,
                alignment: .leading
            )
            .background(
                dayState.feeling == nil ? AppTheme.surface : AppTheme.accentSoft,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.divider.opacity(0.65), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !expands, vertical: false)
        .disabled(controlsDisabled)
        .accessibilityLabel("每日感受")
        .accessibilityValue(dayState.feeling?.label ?? "未设置")
        .accessibilityHint("打开五级感受选择")
    }

    private func importantToggle(expands: Bool) -> some View {
        Toggle(isOn: importantBinding) {
            HStack(spacing: 8) {
                Image(systemName: effectiveImportantValue ? "heart.fill" : "heart")
                    .foregroundStyle(
                        effectiveImportantValue ? AppTheme.accent : AppTheme.mutedInk
                    )
                    .accessibilityHidden(true)

                Text("重要的一天")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if isSettingImportant {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
        }
        .tint(AppTheme.accent)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(
            maxWidth: expands ? .infinity : nil,
            minHeight: 44,
            alignment: .leading
        )
        .background(
            effectiveImportantValue ? AppTheme.accentSoft : AppTheme.surface,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.divider.opacity(0.65), lineWidth: 1)
        }
        .fixedSize(horizontal: !expands, vertical: false)
        .disabled(controlsDisabled)
        .accessibilityLabel("重要的一天")
        .accessibilityValue(importantAccessibilityValue)
    }

    private var feelingButtonTitle: String {
        dayState.feeling.map { "感受 · \($0.label)" } ?? "选择每日感受"
    }

    private var controlsDisabled: Bool {
        isSaving || isSettingFeeling || isSettingImportant
    }

    private var isFeelingControlDisabled: Bool {
        isSaving || isSettingFeeling
    }

    private var effectiveImportantValue: Bool {
        pendingImportantValue ?? dayState.isImportant
    }

    private var importantBinding: Binding<Bool> {
        Binding(
            get: { effectiveImportantValue },
            set: { setImportant($0) }
        )
    }

    private var importantAccessibilityValue: String {
        let value = effectiveImportantValue ? "已标记" : "未标记"
        return isSettingImportant ? "\(value)，正在保存" : value
    }

    private func setFeeling(_ feeling: DailyFeeling?) {
        guard !isFeelingControlDisabled, dayState.feeling != feeling else {
            return
        }

        isSettingFeeling = true
        Task { @MainActor in
            await onSetFeeling(feeling)
            isSettingFeeling = false
            isFeelingPickerPresented = false
        }
    }

    private func setImportant(_ isImportant: Bool) {
        guard !controlsDisabled else {
            return
        }

        pendingImportantValue = isImportant
        isSettingImportant = true
        Task { @MainActor in
            await onSetImportant(isImportant)
            pendingImportantValue = nil
            isSettingImportant = false
        }
    }
}
