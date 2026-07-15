import SwiftUI

struct JournalDocumentView: View {
    let version: JournalVersion
    let photoLibrary: any PhotoLibrary
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 18) {
            Text(version.title.isEmpty ? "未命名随心日记" : version.title)
                .font(isCompact ? .title3.bold() : .title.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)

            ForEach(displayedBlocks) { block in
                switch block.content {
                case let .text(text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(AppTheme.ink)
                            .lineSpacing(6)
                            .lineLimit(isCompact ? 5 : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .photo(photoBlock):
                    VStack(alignment: .leading, spacing: 7) {
                        PhotoAssetView(
                            photoLibrary: photoLibrary,
                            relativePath: photoBlock.photo.thumbnailRelativePath,
                            maxPixelSize: isCompact ? 800 : 1_600,
                            accessibilityLabel: "日记照片"
                        )
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        if !photoBlock.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(photoBlock.caption)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if isCompact && version.blocks.count > displayedBlocks.count {
                Text("还有更多内容")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
            }
        }
    }

    private var displayedBlocks: [JournalBlock] {
        guard isCompact else {
            return version.blocks
        }
        return Array(version.blocks.prefix(3))
    }
}
