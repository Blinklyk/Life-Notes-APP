import SwiftUI

struct JournalSection: View {
    let dayKey: DayKey
    @ObservedObject var model: JournalModel
    let photoLibrary: any PhotoLibrary
    var onJournalChanged: () -> Void = {}

    @State private var editorPresentation: JournalEditorPresentation?
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.isLoading && model.selectedDay == dayKey && model.currentVersion == nil {
                ProgressView("正在读取随心日记")
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else if model.selectedDay == dayKey, let version = model.currentVersion {
                currentJournal(version)
            } else {
                emptyJournal
            }
        }
        .task(id: dayKey) {
            await model.load(day: dayKey, showError: true)
        }
        .sheet(item: $editorPresentation) { presentation in
            JournalEditorView(
                dayKey: dayKey,
                model: model,
                photoLibrary: photoLibrary,
                availablePhotos: availablePhotos,
                initialTitle: presentation.title,
                initialBlocks: presentation.blocks,
                onSaved: onJournalChanged
            )
        }
        .sheet(isPresented: $showsHistory) {
            JournalHistoryView(
                model: model,
                photoLibrary: photoLibrary,
                onRestored: onJournalChanged
            )
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text("随心日记"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("随心日记")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Spacer(minLength: 8)
            if let version = model.currentVersion, model.selectedDay == dayKey {
                Text("版本 \(version.versionNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func currentJournal(_ version: JournalVersion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.hasNewSourceMaterial {
                Label("有新内容，可更新", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityAddTraits(.isStaticText)
            }

            JournalDocumentView(
                version: version,
                photoLibrary: photoLibrary,
                isCompact: true
            )

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    editButton(version)
                    historyButton
                    regenerateButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    editButton(version)
                    HStack(spacing: 8) {
                        historyButton
                        regenerateButton
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.divider.opacity(0.65), lineWidth: 1)
        }
    }

    private var emptyJournal: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedInk)

            Picker("表达风格", selection: $model.writingStyle) {
                ForEach(WritingStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    generateButton
                    handwriteButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    generateButton
                    handwriteButton
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.divider.opacity(0.65), lineWidth: 1)
        }
    }

    private var emptyMessage: String {
        if model.selectedDay != dayKey || model.isLoading {
            return "正在准备这一天的随心日记。"
        }
        if model.sourceEntries.isEmpty {
            return "这一天还没有随心记录，也可以先手写一篇日记。"
        }
        if !model.canGenerate {
            return "当前素材没有文字、图片批注或语音转写，可以先手写。"
        }
        return "根据这一天的文字、图片批注和语音转写生成一篇初稿。"
    }

    private var generateButton: some View {
        Button {
            Task {
                if await model.generate() {
                    onJournalChanged()
                }
            }
        } label: {
            Label(
                model.isGenerating ? "正在生成" : "生成日记",
                systemImage: "wand.and.stars"
            )
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
        .disabled(!model.canGenerate)
    }

    private var handwriteButton: some View {
        Button {
            editorPresentation = JournalEditorPresentation(title: "", blocks: [])
        } label: {
            Label("手写一篇", systemImage: "square.and.pencil")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy || model.selectedDay != dayKey)
    }

    private func editButton(_ version: JournalVersion) -> some View {
        Button {
            editorPresentation = JournalEditorPresentation(
                title: version.title,
                blocks: version.blocks
            )
        } label: {
            Label("编辑", systemImage: "square.and.pencil")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    private var historyButton: some View {
        Button {
            showsHistory = true
        } label: {
            Label("历史", systemImage: "clock.arrow.circlepath")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    private var regenerateButton: some View {
        Menu {
            Picker("表达风格", selection: $model.writingStyle) {
                ForEach(WritingStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }

            Button {
                Task {
                    if await model.regenerate() {
                        onJournalChanged()
                    }
                }
            } label: {
                Label(
                    model.hasNewSourceMaterial ? "使用新内容生成" : "重新生成新版本",
                    systemImage: "wand.and.stars"
                )
            }
            .disabled(!model.canGenerate)
        } label: {
            Label(
                model.hasNewSourceMaterial ? "更新" : "重新生成",
                systemImage: "arrow.clockwise"
            )
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
        .disabled(model.isBusy)
    }

    private var availablePhotos: [PhotoAttachment] {
        model.sourceEntries.flatMap { entry in
            JournalSourceOrdering.photos(entry.photos)
        }
    }
}

private struct JournalEditorPresentation: Identifiable {
    let id = UUID()
    let title: String
    let blocks: [JournalBlock]
}
