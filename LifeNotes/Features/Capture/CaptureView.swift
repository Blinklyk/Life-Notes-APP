import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CaptureView: View {
    @ObservedObject var appModel: AppModel
    @FocusState private var isEditorFocused: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var presentedPhoto: FullScreenPhotoItem?
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

                if !appModel.isCaptureDraftAvailable {
                    Label(
                        "草稿暂时无法读取。为避免覆盖原内容，当前记录已暂停，请重新打开 App 后再试。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedInk)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 20)
                    .accessibilityElement(children: .combine)
                }

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
                .disabled(!appModel.isCaptureDraftAvailable)
                .accessibilityLabel("随心记录正文")

                photoPicker

                if !appModel.draftPhotos.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(Array(appModel.draftPhotos.enumerated()), id: \.element.id) { index, photo in
                            DraftPhotoRow(
                                draftPhoto: photo,
                                position: index + 1,
                                photoLibrary: appModel.photoLibrary,
                                annotation: Binding(
                                    get: { photo.annotationText },
                                    set: {
                                        appModel.updatePhotoAnnotation(
                                            id: photo.id,
                                            text: $0
                                        )
                                    }
                                ),
                                onRemove: {
                                    appModel.removeDraftPhoto(id: photo.id)
                                },
                                onOpen: { importedPhoto in
                                    presentedPhoto = FullScreenPhotoItem(
                                        id: importedPhoto.id,
                                        relativePath: importedPhoto.originalRelativePath,
                                        accessibilityLabel: "照片 \(index + 1) 原图"
                                    )
                                }
                            )
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .disabled(appModel.isSaving || appModel.isRestoringDraft)
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
            if !appModel.isRestoringDraft {
                isEditorFocused = true
            }
        }
        .onChange(of: appModel.isRestoringDraft) { _, isRestoring in
            if !isRestoring {
                isEditorFocused = true
            }
        }
        .onChange(of: selectedPhotos) { _, newSelection in
            guard !newSelection.isEmpty else {
                return
            }

            let pendingImports: [PendingPhotoImport] = newSelection.compactMap {
                item -> PendingPhotoImport? in
                guard let id = appModel.beginPhotoImport() else {
                    return nil
                }
                return PendingPhotoImport(id: id, item: item)
            }
            let rejectedCount = newSelection.count - pendingImports.count
            selectedPhotos = []
            Task {
                await importPhotos(
                    pendingImports,
                    initialFailureCount: rejectedCount
                )
            }
        }
        .fullScreenCover(item: $presentedPhoto) { photo in
            FullScreenPhotoViewer(
                item: photo,
                photoLibrary: appModel.photoLibrary
            )
        }
    }

    private func importPhotos(
        _ imports: [PendingPhotoImport],
        initialFailureCount: Int
    ) async {
        var successCount = 0
        var failureCount = initialFailureCount

        for pendingImport in imports {
            do {
                guard let transferredFile = try await pendingImport.item.loadTransferable(
                    type: PhotoImportFile.self
                ) else {
                    appModel.failPhotoImport(id: pendingImport.id)
                    failureCount += 1
                    continue
                }
                defer {
                    try? FileManager.default.removeItem(at: transferredFile.fileURL)
                }
                let contentTypeIdentifier = pendingImport.item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .identifier ?? UTType.image.identifier
                let photo = try await appModel.photoLibrary.importPhoto(
                    id: pendingImport.id,
                    fileURL: transferredFile.fileURL,
                    contentTypeIdentifier: contentTypeIdentifier
                )
                appModel.completePhotoImport(id: pendingImport.id, photo: photo)
                successCount += 1
            } catch {
                appModel.failPhotoImport(id: pendingImport.id)
                failureCount += 1
            }
        }

        let announcement: String
        if successCount > 0, failureCount > 0 {
            announcement = "已添加 \(successCount) 张图片，\(failureCount) 张导入失败"
        } else if successCount > 0 {
            announcement = "已添加 \(successCount) 张图片"
        } else if failureCount > 0 {
            announcement = "\(failureCount) 张图片导入失败"
        } else {
            announcement = "未添加图片，草稿已达到图片数量上限"
        }
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private var photoPickerAccessibilityValue: String {
        if appModel.isRestoringDraft {
            return "正在恢复草稿"
        }
        if appModel.isImportingPhotos {
            return "正在导入图片"
        }
        if appModel.remainingPhotoCapacity == 0 {
            return "已达到图片数量上限"
        }
        if !appModel.canAddPhoto {
            return "暂时无法添加图片"
        }
        return "还可添加 \(appModel.remainingPhotoCapacity) 张"
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: max(appModel.remainingPhotoCapacity, 1),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current
        ) {
            PhotoPickerLabel()
        }
        .buttonStyle(.plain)
        .disabled(!appModel.canAddPhoto || appModel.isImportingPhotos)
        .accessibilityLabel("从相册添加图片")
        .accessibilityValue(photoPickerAccessibilityValue)
        .padding(.top, 16)
    }
}

private struct PhotoPickerLabel: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3.weight(.semibold))
                .accessibilityHidden(true)
            Text("从相册添加")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 12)
            Image(systemName: "plus")
                .font(.callout.bold())
                .accessibilityHidden(true)
        }
        .foregroundStyle(AppTheme.accent)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingPhotoImport {
    let id: UUID
    let item: PhotosPickerItem
}

private struct PhotoImportFile: Transferable, Sendable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { receivedFile in
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "LifeNotesPickerImport-\(UUID().uuidString)"
                )
            do {
                try FileManager.default.copyItem(
                    at: receivedFile.file,
                    to: destinationURL
                )
                return PhotoImportFile(fileURL: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }
}

private struct DraftPhotoRow: View {
    let draftPhoto: AppModel.DraftPhoto
    let position: Int
    let photoLibrary: any PhotoLibrary
    @Binding var annotation: String
    let onRemove: () -> Void
    let onOpen: (ImportedPhoto) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("照片 \(position)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
                Spacer(minLength: 12)
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除照片 \(position)")
                .help("移除照片")
            }

            switch draftPhoto.state {
            case .importing:
                photoPlaceholder {
                    ProgressView("正在导入")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .accessibilityLabel("正在导入照片 \(position)")

            case .failed:
                photoPlaceholder {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("导入失败，请移除后重新选择")
                            .font(.callout)
                    }
                    .foregroundStyle(AppTheme.mutedInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("照片 \(position) 导入失败")

            case let .ready(photo):
                Button {
                    onOpen(photo)
                } label: {
                    PhotoAssetView(
                        photoLibrary: photoLibrary,
                        relativePath: photo.thumbnailRelativePath,
                        displayMode: .fit,
                        maxPixelSize: 1_200,
                        accessibilityLabel: "照片 \(position)"
                    )
                    .aspectRatio(photoAspectRatio(photo), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开原图")

                TextField(
                    "照片 \(position) 的批注",
                    text: $annotation,
                    prompt: Text("可选批注"),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .frame(minHeight: 44, alignment: .leading)
                .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.divider, lineWidth: 1)
                }
                .accessibilityLabel("照片 \(position) 的可选批注")
            }
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.divider.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func photoPlaceholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        AppTheme.accentSoft.opacity(0.55)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                content()
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func photoAspectRatio(_ photo: ImportedPhoto) -> CGFloat {
        CGFloat(max(photo.pixelWidth, 1)) / CGFloat(max(photo.pixelHeight, 1))
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
