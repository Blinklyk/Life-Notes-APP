import SwiftUI

struct DayDetailView: View {
    let dayKey: DayKey
    @ObservedObject var appModel: AppModel
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var journalModel: JournalModel
    @ObservedObject var entryLibraryModel: EntryLibraryModel
    let onEditEntry: (Entry) -> Void
    let onDeleteEntry: (Entry) -> Void
    @State private var presentedPhoto: FullScreenPhotoItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppDateFormatting.calendarDayHeading(dayKey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)

                Text("日期详情")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.ink)
                    .padding(.top, 5)
                    .accessibilityAddTraits(.isHeader)

                detailContent
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dayKey) {
            await calendarModel.loadDetail(for: dayKey, showError: true)
        }
        .onChange(of: calendarModel.detail?.entries) { _, detailEntries in
            guard calendarModel.detail?.dayKey == dayKey, detailEntries != nil else {
                return
            }
            Task {
                await journalModel.load(day: dayKey, showError: false)
            }
        }
        .onDisappear {
            appModel.stopVoicePlayback()
        }
        .fullScreenCover(item: $presentedPhoto) { photo in
            FullScreenPhotoViewer(
                item: photo,
                photoLibrary: appModel.photoLibrary
            )
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let detail = calendarModel.detail, detail.dayKey == dayKey {
            DayStateEditor(
                dayState: detail.state,
                isSaving: calendarModel.isUpdatingDayState || calendarModel.isLoadingDetail,
                onSetFeeling: { feeling in
                    await calendarModel.setFeeling(feeling)
                },
                onSetImportant: { isImportant in
                    await calendarModel.setImportant(isImportant)
                }
            )
            .padding(.top, 20)

            JournalSection(
                dayKey: dayKey,
                model: journalModel,
                photoLibrary: appModel.photoLibrary,
                onJournalChanged: {
                    Task {
                        await calendarModel.loadMonth(showError: false)
                    }
                }
            )
            .padding(.top, 28)

            HStack(alignment: .firstTextBaseline) {
                Text("随心记录")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer(minLength: 12)
                Text("按时间排列 · \(detail.entries.count) 条")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .padding(.top, 28)
            .accessibilityElement(children: .combine)

            if detail.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.minus")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text("这一天还没有随心记录")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                .accessibilityElement(children: .combine)
            } else {
                EntryTimeline(
                    entries: detail.entries,
                    timeZone: .autoupdatingCurrent,
                    appModel: appModel,
                    photoLibrary: appModel.photoLibrary,
                    busyEntryIDs: entryLibraryModel.busyEntryIDs,
                    onOpenPhoto: { photo, position in
                        presentedPhoto = FullScreenPhotoItem(
                            id: photo.id,
                            relativePath: photo.originalRelativePath,
                            accessibilityLabel: "照片 \(position) 原图"
                        )
                    },
                    onEditVoice: { _ in },
                    onEditEntry: onEditEntry,
                    onDeleteEntry: onDeleteEntry,
                    allowsVoiceEditing: false
                )
                .padding(.top, 18)
            }
        } else if calendarModel.isLoadingDetail {
            ProgressView("正在读取日期详情")
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            Button("重新加载") {
                Task {
                    await calendarModel.loadDetail(for: dayKey, showError: true)
                }
            }
            .font(.headline)
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.top, 64)
        }
    }
}
