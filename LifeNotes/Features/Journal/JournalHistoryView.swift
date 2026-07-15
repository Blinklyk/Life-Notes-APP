import SwiftUI

struct JournalHistoryView: View {
    @ObservedObject var model: JournalModel
    let photoLibrary: any PhotoLibrary
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selectedVersion {
                        versionMetadata(selectedVersion)
                        JournalDocumentView(
                            version: selectedVersion,
                            photoLibrary: photoLibrary
                        )

                        if selectedVersion.id != model.currentVersion?.id {
                            Button {
                                restoreSelectedVersion()
                            } label: {
                                Label("恢复为新版本", systemImage: "arrow.uturn.backward.circle")
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                            .disabled(model.isSaving)
                        }
                    }

                    Divider()

                    Text("全部版本")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)

                    ForEach(model.journalDay?.allVersions ?? []) { version in
                        Button {
                            model.preview(version)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("版本 \(version.versionNumber) · \(originLabel(version.origin))")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedInk)
                                }
                                Spacer(minLength: 8)
                                if version.id == model.currentVersion?.id {
                                    Text("当前")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.sage)
                                }
                                Image(systemName: version.id == selectedVersion?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(AppTheme.accent)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "版本 \(version.versionNumber)，\(originLabel(version.origin))"
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(AppTheme.paper.ignoresSafeArea())
            .navigationTitle("日记历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭历史版本")
                    .help("关闭")
                    .disabled(model.isSaving)
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .onAppear {
                if let currentVersion = model.currentVersion {
                    model.preview(currentVersion)
                }
            }
            .onDisappear {
                model.dismissPreview()
            }
        }
    }

    private var selectedVersion: JournalVersion? {
        model.previewedVersion ?? model.currentVersion
    }

    private func versionMetadata(_ version: JournalVersion) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("版本 \(version.versionNumber)")
                Text(originLabel(version.origin))
                Spacer(minLength: 8)
                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("版本 \(version.versionNumber) · \(originLabel(version.origin))")
                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppTheme.sage)
        .accessibilityElement(children: .combine)
    }

    private func originLabel(_ origin: JournalVersionOrigin) -> String {
        switch origin {
        case .generated:
            return "生成"
        case .edited:
            return "编辑"
        case .restored:
            return "恢复"
        }
    }

    private func restoreSelectedVersion() {
        Task {
            if await model.restorePreviewedVersion() {
                onRestored()
                dismiss()
            }
        }
    }
}
