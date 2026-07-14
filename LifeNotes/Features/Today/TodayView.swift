import SwiftUI

struct TodayView: View {
    @ObservedObject var appModel: AppModel
    @AccessibilityFocusState private var isTitleFocused: Bool
    @State private var presentedPhoto: FullScreenPhotoItem?
    @State private var editingVoice: VoiceAttachment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodayHeader(
                    date: appModel.todayDate,
                    timeZone: appModel.todayTimeZone,
                    onNewEntry: { appModel.showCapture() },
                    isTitleFocused: $isTitleFocused
                )

                DayStateEditor(
                    dayState: appModel.dayState,
                    isSaving: appModel.isUpdatingDayState || appModel.isLoadingToday,
                    onSetFeeling: { feeling in
                        await appModel.setFeeling(feeling)
                    },
                    onSetImportant: { isImportant in
                        await appModel.setImportant(isImportant)
                    }
                )
                .padding(.top, 20)

                HStack(alignment: .firstTextBaseline) {
                    Text("随心记录")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Spacer(minLength: 12)
                    Text("按时间排列 · \(appModel.entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .padding(.top, 28)
                .accessibilityElement(children: .combine)

                if appModel.isLoadingToday && appModel.entries.isEmpty {
                    ProgressView("正在读取今天的记录")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                } else if appModel.entries.isEmpty {
                    TodayEmptyState()
                        .padding(.top, 64)
                } else {
                    EntryTimeline(
                        entries: appModel.entries,
                        timeZone: appModel.todayTimeZone,
                        appModel: appModel,
                        photoLibrary: appModel.photoLibrary,
                        onOpenPhoto: { photo, position in
                            presentedPhoto = FullScreenPhotoItem(
                                id: photo.id,
                                relativePath: photo.originalRelativePath,
                                accessibilityLabel: "照片 \(position) 原图"
                            )
                        },
                        onEditVoice: { editingVoice = $0 }
                    )
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = appModel.notice {
                Text(notice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainTabBar(
                selection: .today,
                onToday: {},
                onNewEntry: { appModel.showCapture() },
                onCalendar: { appModel.showCalendar() }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.notice)
        .task {
            isTitleFocused = true
            await appModel.refreshToday()
        }
        .fullScreenCover(item: $presentedPhoto) { photo in
            FullScreenPhotoViewer(
                item: photo,
                photoLibrary: appModel.photoLibrary
            )
        }
        .sheet(item: $editingVoice) { voice in
            VoiceTranscriptEditor(
                appModel: appModel,
                voice: voice
            )
        }
    }
}

private struct TodayHeader: View {
    let date: Date
    let timeZone: TimeZone
    let onNewEntry: () -> Void
    let isTitleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                newEntryButton
            }

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                newEntryButton
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppDateFormatting.dayHeading(date, timeZone: timeZone))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sage)

            Text("今天")
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(isTitleFocused)
        }
    }

    private var newEntryButton: some View {
        Button(action: onNewEntry) {
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("立即记录")
        .help("立即记录")
    }
}

struct EntryTimeline: View {
    let entries: [Entry]
    let timeZone: TimeZone
    @ObservedObject var appModel: AppModel
    let photoLibrary: any PhotoLibrary
    let onOpenPhoto: (PhotoAttachment, Int) -> Void
    let onEditVoice: (VoiceAttachment) -> Void
    var allowsVoiceEditing = true

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                EntryTimelineRow(
                    entry: entry,
                    timeZone: timeZone,
                    isLast: index == entries.count - 1,
                    appModel: appModel,
                    photoLibrary: photoLibrary,
                    onOpenPhoto: onOpenPhoto,
                    onEditVoice: onEditVoice,
                    allowsVoiceEditing: allowsVoiceEditing
                )
            }
        }
    }
}

private struct EntryTimelineRow: View {
    let entry: Entry
    let timeZone: TimeZone
    let isLast: Bool
    @ObservedObject var appModel: AppModel
    let photoLibrary: any PhotoLibrary
    let onOpenPhoto: (PhotoAttachment, Int) -> Void
    let onEditVoice: (VoiceAttachment) -> Void
    let allowsVoiceEditing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.paper, lineWidth: 2)
                    }

                if !isLast {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(AppDateFormatting.entryTime(entry.createdAt, timeZone: entryTimeZone))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
                    .accessibilityLabel(
                        AppDateFormatting.accessibleEntryTime(
                            entry.createdAt,
                            timeZone: entryTimeZone
                        )
                    )

                if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.text)
                        .font(.body)
                        .foregroundStyle(AppTheme.ink)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(Array(entry.photos.enumerated()), id: \.element.id) { index, photo in
                    VStack(alignment: .leading, spacing: 8) {
                        EntryPhotoView(
                            photo: photo,
                            position: index + 1,
                            photoLibrary: photoLibrary,
                            onOpen: { onOpenPhoto(photo, index + 1) }
                        )

                        ForEach(voices(targeting: photo.id)) { voice in
                            PhotoVoiceAnnotationView(
                                appModel: appModel,
                                voice: voice,
                                photoPosition: index + 1,
                                isOrphaned: false,
                                onEdit: { onEditVoice(voice) },
                                allowsVoiceEditing: allowsVoiceEditing
                            )
                        }
                    }
                }

                ForEach(unattachedVoices) { voice in
                    if voice.targetPhotoID == nil {
                        GlobalVoiceView(
                            appModel: appModel,
                            voice: voice,
                            onEdit: { onEditVoice(voice) },
                            allowsVoiceEditing: allowsVoiceEditing
                        )
                    } else {
                        PhotoVoiceAnnotationView(
                            appModel: appModel,
                            voice: voice,
                            photoPosition: nil,
                            isOrphaned: true,
                            onEdit: { onEditVoice(voice) },
                            allowsVoiceEditing: allowsVoiceEditing
                        )
                    }
                }
            }
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.divider.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: AppTheme.ink.opacity(0.04), radius: 10, y: 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var photoIDs: Set<UUID> {
        Set(entry.photos.map(\.id))
    }

    private var entryTimeZone: TimeZone {
        TimeZone(identifier: entry.creationTimeZoneIdentifier) ?? timeZone
    }

    private var unattachedVoices: [VoiceAttachment] {
        entry.voices.filter { voice in
            guard let targetPhotoID = voice.targetPhotoID else {
                return true
            }
            return !photoIDs.contains(targetPhotoID)
        }
    }

    private func voices(targeting photoID: UUID) -> [VoiceAttachment] {
        entry.voices.filter { $0.targetPhotoID == photoID }
    }
}

private struct GlobalVoiceView: View {
    @ObservedObject var appModel: AppModel
    let voice: VoiceAttachment
    let onEdit: () -> Void
    let allowsVoiceEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("整条记录语音", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sage)

            EntryVoiceView(
                appModel: appModel,
                voice: voice,
                onEdit: onEdit,
                allowsVoiceEditing: allowsVoiceEditing
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PhotoVoiceAnnotationView: View {
    @ObservedObject var appModel: AppModel
    let voice: VoiceAttachment
    let photoPosition: Int?
    let isOrphaned: Bool
    let onEdit: () -> Void
    let allowsVoiceEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                isOrphaned ? "语音批注 · 对应照片不可用" : "语音批注",
                systemImage: isOrphaned ? "exclamationmark.triangle" : "waveform"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOrphaned ? AppTheme.accent : AppTheme.sage)
            .accessibilityLabel(accessibilityTitle)

            EntryVoiceView(
                appModel: appModel,
                voice: voice,
                onEdit: onEdit,
                allowsVoiceEditing: allowsVoiceEditing
            )
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isOrphaned ? AppTheme.accent : AppTheme.divider)
                .frame(width: 2)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private var accessibilityTitle: String {
        if let photoPosition {
            return "照片 \(photoPosition) 的语音批注"
        }
        return "语音批注，对应照片不可用"
    }
}

private struct EntryVoiceView: View {
    @ObservedObject var appModel: AppModel
    let voice: VoiceAttachment
    let onEdit: () -> Void
    let allowsVoiceEditing: Bool

    private var isTranscribing: Bool {
        appModel.transcribingSavedVoiceIDs.contains(voice.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let relativePath = voice.originalRelativePath {
                VoicePlaybackView(
                    appModel: appModel,
                    voiceID: voice.id,
                    relativePath: relativePath,
                    durationMilliseconds: voice.durationMilliseconds
                )
            } else {
                Label("仅保留转写", systemImage: "text.quote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
            }

            HStack(alignment: .top, spacing: 10) {
                if isTranscribing {
                    ProgressView()
                    Text("正在转写")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedInk)
                } else {
                    Label(
                        statusLabel,
                        systemImage: statusIcon
                    )
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
                }

                Spacer(minLength: 12)

                if allowsVoiceEditing, canRetry {
                    Button {
                        appModel.retrySavedVoiceTranscription(voice)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重试语音转写")
                    .help("重试转写")
                }

                if allowsVoiceEditing {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTranscribing)
                    .accessibilityLabel("编辑语音转写")
                    .accessibilityHint(isTranscribing ? "转写完成后可以编辑" : "")
                    .help("编辑转写")
                }
            }

            if !voice.transcriptText.isEmpty {
                Text(voice.transcriptText)
                    .font(.callout)
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("语音转写：\(voice.transcriptText)")
            }
        }
        .padding(.top, 4)
    }

    private var canRetry: Bool {
        voice.originalRelativePath != nil
            && !voice.isTranscriptUserEdited
            && appModel.transcribingSavedVoiceIDs.isEmpty
            && voice.transcriptionStatus != .completed
    }

    private var statusLabel: String {
        if voice.isTranscriptUserEdited {
            return "转写已编辑"
        }
        switch voice.transcriptionStatus {
        case .notRequested:
            return "尚未转写"
        case .pending:
            return "等待转写"
        case .completed:
            switch voice.transcriptionSource {
            case .onDevice:
                return "设备内转写完成"
            case .appleNetwork:
                return "Apple 网络转写完成"
            case .manual:
                return "转写已编辑"
            case nil:
                return "转写完成"
            }
        case .failed:
            return "转写失败"
        case .permissionDenied:
            return "未授权语音识别"
        }
    }

    private var statusIcon: String {
        if voice.isTranscriptUserEdited {
            return "pencil.circle"
        }
        switch voice.transcriptionStatus {
        case .completed:
            return "checkmark.circle"
        case .failed, .permissionDenied:
            return "exclamationmark.circle"
        case .notRequested, .pending:
            return "text.bubble"
        }
    }
}

struct VoiceTranscriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appModel: AppModel
    let voice: VoiceAttachment
    @State private var text: String
    @State private var isSaving = false

    init(appModel: AppModel, voice: VoiceAttachment) {
        self.appModel = appModel
        self.voice = voice
        _text = State(initialValue: voice.transcriptText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .foregroundStyle(AppTheme.ink)
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(AppTheme.paper)
                .navigationTitle("编辑转写")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            isSaving = true
                            Task {
                                if await appModel.updateSavedVoiceTranscript(
                                    voice,
                                    text: text
                                ) {
                                    dismiss()
                                }
                                isSaving = false
                            }
                        }
                        .disabled(isSaving)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving)
    }
}

private struct EntryPhotoView: View {
    let photo: PhotoAttachment
    let position: Int
    let photoLibrary: any PhotoLibrary
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                PhotoAssetView(
                    photoLibrary: photoLibrary,
                    relativePath: photo.thumbnailRelativePath,
                    displayMode: .fit,
                    maxPixelSize: 1_200,
                    accessibilityLabel: "照片 \(position)"
                )
                .aspectRatio(photoAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开原图")

            if !photo.annotationText.isEmpty {
                Text(photo.annotationText)
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedInk)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("照片 \(position) 批注：\(photo.annotationText)")
            }
        }
    }

    private var photoAspectRatio: CGFloat {
        CGFloat(max(photo.pixelWidth, 1)) / CGFloat(max(photo.pixelHeight, 1))
    }
}

private struct TodayEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)

            Text("今天还没有随心记录")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            Text("这一刻值得留下一点什么。")
                .font(.body)
                .foregroundStyle(AppTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
