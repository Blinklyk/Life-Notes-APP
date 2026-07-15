import SwiftUI

struct EntryEditorView: View {
    let entry: Entry
    @ObservedObject var model: EntryLibraryModel
    @ObservedObject var appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var privacyGate: PrivacyGateModel
    private let initialEdit: EntryEdit
    @State private var text: String
    @State private var photoAnnotations: [UUID: String]
    @State private var voiceTranscripts: [UUID: String]
    @State private var isSubmitting = false
    @State private var showsDiscardConfirmation = false

    init(
        entry: Entry,
        model: EntryLibraryModel,
        appModel: AppModel
    ) {
        self.entry = entry
        self.model = model
        self.appModel = appModel

        let annotations = Dictionary(
            uniqueKeysWithValues: entry.photos.map { ($0.id, $0.annotationText) }
        )
        let transcripts = Dictionary(
            uniqueKeysWithValues: entry.voices.map { ($0.id, $0.transcriptText) }
        )
        initialEdit = EntryEdit(entry: entry)
        _text = State(initialValue: entry.text)
        _photoAnnotations = State(initialValue: annotations)
        _voiceTranscripts = State(initialValue: transcripts)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text(AppDateFormatting.calendarDayHeading(entry.dayKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.sage)

                    textEditor

                    ForEach(Array(entry.photos.enumerated()), id: \.element.id) { index, photo in
                        photoEditor(photo, position: index + 1)
                    }

                    ForEach(entry.voices) { voice in
                        voiceEditor(voice)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .disabled(isEditingDisabled)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.paper.ignoresSafeArea())
            .navigationTitle("编辑随心记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(isEditingDisabled)
                    .accessibilityLabel("取消编辑")
                    .help("取消编辑")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                            .accessibilityLabel("正在保存随心记录")
                    } else {
                        Button("保存") {
                            save()
                        }
                        .fontWeight(.semibold)
                        .disabled(isEditingDisabled || !canSave)
                    }
                }
            }
            .interactiveDismissDisabled(isEditingDisabled || hasUnsavedChanges)
            .confirmationDialog(
                "放弃未保存的修改？",
                isPresented: $showsDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("放弃修改", role: .destructive) {
                    guard !isEditingDisabled else {
                        return
                    }
                    model.cancelEditing()
                    dismiss()
                }
                .disabled(isEditingDisabled)
                Button("继续编辑", role: .cancel) {}
                    .disabled(isEditingDisabled)
            }
        }
        .onChange(of: privacyGate.isContentCovered) { _, isCovered in
            if isCovered {
                showsDiscardConfirmation = false
            }
        }
        .privacyProtectedPresentation()
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("正文", systemImage: "text.alignleft")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            TextEditor(text: guardedTextBinding)
                .font(.body)
                .foregroundStyle(AppTheme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(10)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.divider, lineWidth: 1)
                }
                .accessibilityLabel("随心记录正文")
        }
    }

    private func photoEditor(_ photo: PhotoAttachment, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("照片 \(position)", systemImage: "photo")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            PhotoAssetView(
                photoLibrary: appModel.photoLibrary,
                relativePath: photo.thumbnailRelativePath,
                maxPixelSize: 1_200,
                accessibilityLabel: "照片 \(position)"
            )
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            TextField(
                "图片批注（可不填）",
                text: photoAnnotationBinding(for: photo.id),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1 ... 5)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("照片 \(position) 的文字批注")
        }
    }

    private func voiceEditor(_ voice: VoiceAttachment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(voiceLabel(voice), systemImage: "waveform")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            if let relativePath = voice.originalRelativePath {
                VoicePlaybackView(
                    appModel: appModel,
                    voiceID: voice.id,
                    relativePath: relativePath,
                    durationMilliseconds: voice.durationMilliseconds
                )
            } else {
                Label("仅保留转写", systemImage: "text.quote")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
            }

            TextEditor(text: voiceTranscriptBinding(for: voice.id))
                .font(.body)
                .foregroundStyle(AppTheme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(10)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.divider, lineWidth: 1)
                }
                .accessibilityLabel("\(voiceLabel(voice))的语音转写")

            if voice.originalRelativePath == nil,
               normalizedTranscript(for: voice.id).isEmpty {
                Label("仅保留转写的录音需要填写转写文字", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }

    private var guardedTextBinding: Binding<String> {
        Binding(
            get: { text },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                text = value
            }
        )
    }

    private func photoAnnotationBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { photoAnnotations[id, default: ""] },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                photoAnnotations[id] = value
            }
        )
    }

    private func voiceTranscriptBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { voiceTranscripts[id, default: ""] },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                voiceTranscripts[id] = value
            }
        )
    }

    private var hasUnsavedChanges: Bool {
        EntryEditorRules.hasUnsavedChanges(initialEdit: initialEdit, pendingEdit: pendingEdit)
    }

    private var canSave: Bool {
        EntryEditorRules.canSave(
            entry: entry,
            initialEdit: initialEdit,
            pendingEdit: pendingEdit
        )
    }

    private var isEditingDisabled: Bool {
        isSubmitting || model.busyEntryIDs.contains(entry.id)
    }

    private func normalizedTranscript(for id: UUID) -> String {
        voiceTranscripts[id, default: ""].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private func voiceLabel(_ voice: VoiceAttachment) -> String {
        guard let targetPhotoID = voice.targetPhotoID,
              let position = entry.photos.firstIndex(where: { $0.id == targetPhotoID }) else {
            return voice.targetPhotoID == nil ? "整条记录录音" : "照片不可用的录音"
        }
        return "照片 \(position + 1) 的录音"
    }

    private func cancel() {
        guard !isEditingDisabled else {
            return
        }
        if hasUnsavedChanges {
            showsDiscardConfirmation = true
        } else {
            model.cancelEditing()
            dismiss()
        }
    }

    private func save() {
        guard canSave, !isEditingDisabled else {
            return
        }

        appModel.stopVoicePlayback()
        isSubmitting = true
        Task {
            if await model.updateEntry(id: entry.id, edit: pendingEdit) {
                model.cancelEditing()
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }

    private var pendingEdit: EntryEdit {
        EntryEdit(
            expectedRevision: entry.revision,
            text: text,
            photoAnnotations: entry.photos.map { photo in
                EntryPhotoAnnotationEdit(
                    photoID: photo.id,
                    annotationText: photoAnnotations[photo.id, default: ""]
                )
            },
            voiceTranscripts: entry.voices.map(makeVoiceEdit)
        )
    }

    private func makeVoiceEdit(_ voice: VoiceAttachment) -> EntryVoiceTranscriptEdit {
        EntryEditorRules.voiceTranscriptEdit(
            voice: voice,
            transcript: normalizedTranscript(for: voice.id)
        )
    }
}

enum EntryEditorRules {
    static func hasUnsavedChanges(
        initialEdit: EntryEdit,
        pendingEdit: EntryEdit
    ) -> Bool {
        pendingEdit != initialEdit
    }

    static func canSave(
        entry: Entry,
        initialEdit: EntryEdit,
        pendingEdit: EntryEdit
    ) -> Bool {
        guard hasUnsavedChanges(initialEdit: initialEdit, pendingEdit: pendingEdit) else {
            return false
        }
        guard !pendingEdit.text.isEmpty || !entry.photos.isEmpty || !entry.voices.isEmpty else {
            return false
        }

        let transcriptsByID = Dictionary(
            uniqueKeysWithValues: pendingEdit.voiceTranscripts.map { ($0.voiceID, $0) }
        )
        guard transcriptsByID.count == entry.voices.count else {
            return false
        }
        return entry.voices.allSatisfy { voice in
            guard let transcript = transcriptsByID[voice.id] else {
                return false
            }
            return voice.originalRelativePath != nil || !transcript.transcriptText.isEmpty
        }
    }

    static func voiceTranscriptEdit(
        voice: VoiceAttachment,
        transcript: String
    ) -> EntryVoiceTranscriptEdit {
        let didChange = transcript != voice.transcriptText
        return EntryVoiceTranscriptEdit(
            voiceID: voice.id,
            transcriptText: transcript,
            transcriptionStatus: didChange
                ? (transcript.isEmpty ? .notRequested : .completed)
                : voice.transcriptionStatus,
            transcriptionSource: didChange
                ? (transcript.isEmpty ? nil : .manual)
                : voice.transcriptionSource,
            isTranscriptUserEdited: didChange ? !transcript.isEmpty : voice.isTranscriptUserEdited,
            sourceLocaleIdentifier: voice.sourceLocaleIdentifier
        )
    }
}
