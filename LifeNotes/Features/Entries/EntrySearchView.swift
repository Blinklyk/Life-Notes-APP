import SwiftUI

struct EntrySearchView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var entryLibraryModel: EntryLibraryModel
    let onEditEntry: (Entry) -> Void
    let onDeleteEntry: (Entry) -> Void

    @State private var query = ""
    @State private var presentedPhoto: FullScreenPhotoItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !normalizedQuery.isEmpty, isShowingCurrentQuery {
                    resultHeader
                }

                if isAwaitingSearch || entryLibraryModel.isSearching {
                    ProgressView("正在搜索随心记录")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                } else if !normalizedQuery.isEmpty, entryLibraryModel.results.isEmpty {
                    emptyResult
                        .padding(.top, 64)
                } else if !entryLibraryModel.results.isEmpty {
                    EntryTimeline(
                        entries: entryLibraryModel.results,
                        timeZone: .autoupdatingCurrent,
                        appModel: appModel,
                        photoLibrary: appModel.photoLibrary,
                        busyEntryIDs: entryLibraryModel.busyEntryIDs,
                        onOpenPhoto: openPhoto,
                        onEditVoice: { _ in },
                        onEditEntry: onEditEntry,
                        onDeleteEntry: onDeleteEntry,
                        allowsVoiceEditing: false
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppTheme.paper.ignoresSafeArea())
        .navigationTitle("搜索记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索随心记录"
        )
        .task(id: query) {
            if normalizedQuery.isEmpty {
                await entryLibraryModel.search(matching: "")
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                await entryLibraryModel.search(matching: query)
            } catch is CancellationError {
                return
            } catch {
                return
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

    private var resultHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("随心记录")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Spacer(minLength: 12)
            Text("\(entryLibraryModel.results.count) 条结果")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyResult: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text("没有匹配的随心记录")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingCurrentQuery: Bool {
        entryLibraryModel.query == normalizedQuery
    }

    private var isAwaitingSearch: Bool {
        !normalizedQuery.isEmpty && !isShowingCurrentQuery
    }

    private func openPhoto(_ photo: PhotoAttachment, position: Int) {
        presentedPhoto = FullScreenPhotoItem(
            id: photo.id,
            relativePath: photo.originalRelativePath,
            accessibilityLabel: "照片 \(position) 原图"
        )
    }
}

struct EntryLibraryNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedInk)
            .accessibilityLabel("关闭提示")
            .help("关闭")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.divider, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
