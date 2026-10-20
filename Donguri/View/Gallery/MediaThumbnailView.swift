//
//  MediaThumbnailView.swift
//  Donguri
//
//  Square thumbnail for an image or video, used under posts, in the
//  gallery's thumbnail strip and in its grid. Decoded thumbnails are shared
//  through MediaStore's memory cache, so a row scrolling back into view, or
//  a thumbnail that was preloaded, draws immediately.
//

import SwiftUI
import UIKit

struct MediaThumbnailView: View {
    let item: MediaItem
    /// Fixed side length, or nil to fill the width offered (grid cells).
    var side: CGFloat? = 84
    var cornerRadius: CGFloat = 8
    /// Decode size. Thumbnails share one size so a preloaded thumbnail is
    /// reused wherever the item appears.
    var pixelSize: CGFloat = MediaThumbnailView.rowPixelSize

    /// 100pt at 3x, so even the large thumbnail setting stays sharp.
    /// Preloading decodes at this size too.
    static let rowPixelSize: CGFloat = 300
    static let gridPixelSize: CGFloat = 360

    @State private var image: UIImage?
    @State private var failed = false

    init(item: MediaItem, side: CGFloat? = 84, cornerRadius: CGFloat = 8,
         pixelSize: CGFloat = MediaThumbnailView.rowPixelSize) {
        self.item = item
        self.side = side
        self.cornerRadius = cornerRadius
        self.pixelSize = pixelSize
        _image = State(initialValue: MediaStore.shared.memoryImage(for: item.url, maxPixelSize: pixelSize))
    }

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(1, contentMode: .fit)
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if item.kind == .unsupportedVideo {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .overlay {
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .task(id: item.id) {
                guard image == nil else { return }
                failed = false
                let loaded = await MediaStore.shared.thumbnail(for: item, maxPixelSize: pixelSize)
                image = loaded
                failed = loaded == nil
            }
    }

    private var badge: String? {
        if item.kind == .unsupportedVideo { return "WebM" }
        if item.isGIF { return "GIF" }
        return nil
    }
}
