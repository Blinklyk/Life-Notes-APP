import SwiftUI

struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackendSettingsModel
    @State private var showsClearConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 后端") {
                    Toggle("使用 AI 生成日记", isOn: $model.isEnabled)

                    TextField(
                        "后端地址",
                        text: $model.baseURLText,
                        prompt: Text("https://example.com")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("AI 后端地址")

                    SecureField(
                        "访问令牌",
                        text: $model.bearerTokenReplacement,
                        prompt: Text(
                            model.hasStoredBearerToken
                                ? "留空以保留已保存令牌"
                                : "输入后端访问令牌"
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityLabel("后端访问令牌")

                    if model.hasStoredBearerToken,
                       model.bearerTokenReplacement.isEmpty {
                        Label("已保存访问令牌", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.sage)
                    }
                }

                Section("连接") {
                    Button {
                        Task { await model.checkHealth() }
                    } label: {
                        HStack(spacing: 10) {
                            if model.isCheckingHealth {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "network")
                            }
                            Text(model.isCheckingHealth ? "正在检查" : "检查后端连接")
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(model.isBusy || model.baseURLText.isEmpty)

                    if let statusMessage = model.statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(AppTheme.sage)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }

                Section("隐私") {
                    Label(
                        "DeepSeek 只会收到所选表达风格、记录正文、非空图片批注和非空语音转写。日期、本地素材标识、图片、原始录音和设备文件路径不会上传。",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedInk)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("清除后端设置", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                    .disabled(model.isBusy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.paper)
            .navigationTitle("AI 与后端")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭设置")
                    .help("关闭")
                    .disabled(model.isBusy)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { _ = await model.save() }
                    } label: {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .accessibilityLabel(model.isSaving ? "正在保存设置" : "保存设置")
                    .help("保存")
                    .disabled(!model.canSave)
                }
            }
            .confirmationDialog(
                "清除后端地址和访问令牌？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清除设置", role: .destructive) {
                    Task { await model.clear() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清除后，随心日记会继续使用本地方式生成。")
            }
            .alert(item: $model.alert) { alert in
                Alert(
                    title: Text("AI 与后端"),
                    message: Text(alert.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .task {
                await model.load()
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear {
            showsClearConfirmation = false
            model.clearSensitiveDraft()
        }
        .privacyProtectedPresentation()
    }
}
