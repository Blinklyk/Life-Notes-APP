import SwiftUI

struct JournalEditorView: View {
    let dayKey: DayKey
    @ObservedObject var model: JournalModel
    let photoLibrary: any PhotoLibrary
    let availablePhotos: [PhotoAttachment]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var privacyGate: PrivacyGateModel
    private let initialTitle: String
    private let initialBlocks: [JournalBlock]
    @State private var title: String
    @State private var blocks: [JournalBlock]
    @State private var showsDiscardConfirmation = false
    @State private var isSubmitting = false

    init(
        dayKey: DayKey,
        model: JournalModel,
        photoLibrary: any PhotoLibrary,
        availablePhotos: [PhotoAttachment],
        initialTitle: String,
        initialBlocks: [JournalBlock],
        onSaved: @escaping () -> Void
    ) {
        self.dayKey = dayKey
        self.model = model
        self.photoLibrary = photoLibrary
        self.availablePhotos = availablePhotos
        self.onSaved = onSaved
        let startingBlocks = initialBlocks.isEmpty
            ? [JournalBlock(text: "")]
            : initialBlocks
        self.initialTitle = initialTitle
        self.initialBlocks = startingBlocks
        _title = State(initialValue: initialTitle)
        _blocks = State(initialValue: startingBlocks)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(AppDateFormatting.calendarDayHeading(dayKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.sage)

                    TextField("日记标题", text: titleBinding, axis: .vertical)
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.ink)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 3)
                        .accessibilityLabel("日记标题")

                    Divider()

                    ForEach(blocks) { block in
                        blockEditor(for: block)
                    }

                    addBlockControls
                        .padding(.top, 4)
                }
                .disabled(isEditingDisabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(AppTheme.paper.ignoresSafeArea())
            .navigationTitle("编辑随心日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("取消编辑")
                    .help("取消编辑")
                    .disabled(isEditingDisabled)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(isEditingDisabled || !hasMeaningfulContent)
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

    @ViewBuilder
    private func blockEditor(for block: JournalBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                blockKindLabel(block)
                Spacer(minLength: 8)
                moveButton(systemName: "arrow.up", blockID: block.id, offset: -1)
                moveButton(systemName: "arrow.down", blockID: block.id, offset: 1)
                Button(role: .destructive) {
                    removeBlock(id: block.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除这个内容块")
                .help("删除")
                .disabled(isEditingDisabled)
            }

            switch block.content {
            case .text:
                TextEditor(text: textBinding(for: block.id))
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .padding(10)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.divider, lineWidth: 1)
                    }
                    .accessibilityLabel("日记正文段落")
            case let .photo(photoBlock):
                VStack(alignment: .leading, spacing: 10) {
                    PhotoAssetView(
                        photoLibrary: photoLibrary,
                        relativePath: photoBlock.photo.thumbnailRelativePath,
                        maxPixelSize: 1_200,
                        accessibilityLabel: "日记照片"
                    )
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    TextField(
                        "照片说明（可不填）",
                        text: captionBinding(for: block.id),
                        axis: .vertical
                    )
                    .font(.callout)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1 ... 4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("照片说明")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func blockKindLabel(_ block: JournalBlock) -> some View {
        Label(
            block.photo == nil ? "文字" : "照片",
            systemImage: block.photo == nil ? "text.alignleft" : "photo"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppTheme.sage)
    }

    private func moveButton(systemName: String, blockID: UUID, offset: Int) -> some View {
        let canMove = canMoveBlock(id: blockID, offset: offset)
        return Button {
            moveBlock(id: blockID, offset: offset)
        } label: {
            Image(systemName: systemName)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isEditingDisabled || !canMove)
        .accessibilityLabel(offset < 0 ? "向上移动" : "向下移动")
        .help(offset < 0 ? "向上移动" : "向下移动")
    }

    private var addBlockControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                addTextButton
                addPhotoMenu
            }

            VStack(alignment: .leading, spacing: 10) {
                addTextButton
                addPhotoMenu
            }
        }
    }

    private var addTextButton: some View {
        Button {
            guard !isEditingDisabled else {
                return
            }
            blocks.append(JournalBlock(text: ""))
        } label: {
            Label("添加文字", systemImage: "text.badge.plus")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(isEditingDisabled)
    }

    private var addPhotoMenu: some View {
        Menu {
            if insertablePhotos.isEmpty {
                Button("没有更多照片") {}
                    .disabled(true)
            } else {
                ForEach(Array(insertablePhotos.enumerated()), id: \.element.id) { index, photo in
                    Button("添加照片 \(index + 1)") {
                        guard !isEditingDisabled else {
                            return
                        }
                        blocks.append(
                            JournalBlock(photo: photo, caption: photo.annotationText)
                        )
                    }
                }
            }
        } label: {
            Label("添加照片", systemImage: "photo.badge.plus")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(isEditingDisabled || insertablePhotos.isEmpty)
    }

    private var insertablePhotos: [PhotoAttachment] {
        let existingIDs = Set(blocks.compactMap(\.photo).map(\.id))
        return availablePhotos.filter { !existingIDs.contains($0.id) }
    }

    private var hasMeaningfulContent: Bool {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return blocks.contains { block in
            switch block.content {
            case let .text(text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .photo:
                return true
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        title != initialTitle || blocks != initialBlocks
    }

    private var isEditingDisabled: Bool {
        isSubmitting || model.isSaving
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                title = value
            }
        )
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let block = blocks.first(where: { $0.id == id }) else {
                    return ""
                }
                return block.text ?? ""
            },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                guard let index = blocks.firstIndex(where: { $0.id == id }) else {
                    return
                }
                blocks[index].content = .text(value)
            }
        )
    }

    private func captionBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                blocks.first(where: { $0.id == id })?.caption ?? ""
            },
            set: { value in
                guard !isEditingDisabled else {
                    return
                }
                guard let index = blocks.firstIndex(where: { $0.id == id }) else {
                    return
                }
                blocks[index].updatePhotoCaption(value)
            }
        )
    }

    private func canMoveBlock(id: UUID, offset: Int) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return blocks.indices.contains(index + offset)
    }

    private func moveBlock(id: UUID, offset: Int) {
        guard !isEditingDisabled else {
            return
        }
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return
        }
        let target = index + offset
        guard blocks.indices.contains(target) else {
            return
        }
        blocks.swapAt(index, target)
    }

    private func removeBlock(id: UUID) {
        guard !isEditingDisabled else {
            return
        }
        blocks.removeAll { $0.id == id }
    }

    private func cancel() {
        guard !isEditingDisabled else {
            return
        }
        if hasUnsavedChanges {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard !isEditingDisabled, hasMeaningfulContent else {
            return
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBlocks = blocks.filter { block in
            guard case let .text(text) = block.content else {
                return true
            }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        isSubmitting = true
        Task {
            if await model.saveEdits(title: normalizedTitle, blocks: normalizedBlocks) {
                onSaved()
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
