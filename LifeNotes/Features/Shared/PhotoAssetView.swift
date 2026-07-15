import SwiftUI
import UIKit

struct PhotoAssetView: View {
    enum DisplayMode {
        case fill
        case fit
    }

    let photoLibrary: any PhotoLibrary
    let relativePath: String
    let displayMode: DisplayMode
    let maxPixelSize: Int?
    let assetAccessibilityLabel: String

    init(
        photoLibrary: any PhotoLibrary,
        relativePath: String,
        displayMode: DisplayMode = .fill,
        maxPixelSize: Int? = nil,
        accessibilityLabel: String = "图片"
    ) {
        self.photoLibrary = photoLibrary
        self.relativePath = relativePath
        self.displayMode = displayMode
        self.maxPixelSize = maxPixelSize
        assetAccessibilityLabel = accessibilityLabel
    }

    var body: some View {
        PhotoAssetLoadingView(
            photoLibrary: photoLibrary,
            relativePath: relativePath,
            maxPixelSize: maxPixelSize,
            accessibilityLabel: assetAccessibilityLabel
        ) { image in
            displayedImage(image)
        }
    }

    @ViewBuilder
    private func displayedImage(_ image: UIImage) -> some View {
        let imageView = Image(uiImage: image)
            .resizable()

        switch displayMode {
        case .fill:
            imageView.scaledToFill()
        case .fit:
            imageView.scaledToFit()
        }
    }
}

struct FullScreenPhotoItem: Identifiable {
    let id: UUID
    let relativePath: String
    let accessibilityLabel: String
}

struct FullScreenPhotoViewer: View {
    let item: FullScreenPhotoItem
    let photoLibrary: any PhotoLibrary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhotoAssetLoadingView(
                photoLibrary: photoLibrary,
                relativePath: item.relativePath,
                maxPixelSize: 4_096,
                accessibilityLabel: item.accessibilityLabel
            ) { image in
                ZoomablePhotoView(image: image)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭原图")
                    .help("关闭原图")
                }
            }
        }
        .privacyProtectedPresentation()
    }
}

private struct PhotoAssetLoadingView<LoadedContent: View>: View {
    let photoLibrary: any PhotoLibrary
    let relativePath: String
    let maxPixelSize: Int?
    let accessibilityLabel: String
    let loadedContent: (UIImage) -> LoadedContent

    @State private var image: UIImage?
    @State private var didFail = false

    init(
        photoLibrary: any PhotoLibrary,
        relativePath: String,
        maxPixelSize: Int?,
        accessibilityLabel: String,
        @ViewBuilder loadedContent: @escaping (UIImage) -> LoadedContent
    ) {
        self.photoLibrary = photoLibrary
        self.relativePath = relativePath
        self.maxPixelSize = maxPixelSize
        self.accessibilityLabel = accessibilityLabel
        self.loadedContent = loadedContent
    }

    var body: some View {
        ZStack {
            AppTheme.accentSoft.opacity(0.55)

            if let image {
                loadedContent(image)
            } else if didFail {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .accessibilityHidden(true)
                    Text("无法显示图片")
                        .font(.caption)
                }
                .foregroundStyle(AppTheme.mutedInk)
            } else {
                ProgressView()
                    .tint(AppTheme.accent)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .task(id: cacheKey) {
            await loadImage()
        }
    }

    private var accessibilityValue: String {
        if image != nil {
            return "已载入"
        }
        return didFail ? "无法显示" : "正在载入"
    }

    private var cacheKey: String {
        "\(relativePath)#\(maxPixelSize.map(String.init) ?? "original")"
    }

    @MainActor
    private func loadImage() async {
        image = nil
        didFail = false

        if let cachedImage = PhotoAssetMemoryCache.shared.image(for: cacheKey) {
            image = cachedImage
            return
        }

        do {
            let data: Data
            if let maxPixelSize {
                data = try await photoLibrary.previewData(
                    for: relativePath,
                    maxPixelSize: max(maxPixelSize, 1)
                )
            } else {
                data = try await photoLibrary.data(for: relativePath)
            }
            try Task.checkCancellation()
            guard let loadedImage = UIImage(data: data) else {
                didFail = true
                return
            }
            PhotoAssetMemoryCache.shared.insert(loadedImage, for: cacheKey)
            image = loadedImage
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}

@MainActor
private final class PhotoAssetMemoryCache {
    static let shared = PhotoAssetMemoryCache()

    private let images: NSCache<NSString, UIImage>

    private init() {
        images = NSCache<NSString, UIImage>()
        images.countLimit = 40
        images.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let pixelCount = image.size.width * image.scale * image.size.height * image.scale
        let cost = min(Int(pixelCount * 4), images.totalCostLimit)
        images.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = context.coordinator.imageView
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.resetZoom(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard context.coordinator.imageView.image !== image else {
            return
        }
        context.coordinator.imageView.image = image
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func resetZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else {
                return
            }
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        }
    }
}
