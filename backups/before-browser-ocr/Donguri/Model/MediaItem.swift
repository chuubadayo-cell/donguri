//
//  MediaItem.swift
//  Donguri
//
//  One image or video linked from a post. The gallery pages through every
//  item in a thread, in post order.
//

import Foundation

nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case image
        case video
        /// WebM: iOS can't play it, so the gallery offers to open it in Safari.
        case unsupportedVideo
    }

    let url: URL
    /// Index into the thread's posts (post number − 1).
    let postIndex: Int
    let kind: Kind

    /// The same link can appear in several posts; each appearance is its own
    /// gallery page, so the post is part of the identity.
    var id: String { "\(postIndex)|\(url.absoluteString)" }

    var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
    var isVideo: Bool { kind != .image }

    /// Every item in a thread, in post order.
    static func items(for posts: [Post]) -> [MediaItem] {
        posts.indices.flatMap { items(in: posts[$0], at: $0) }
    }

    /// Images first, then videos, for one post.
    static func items(in post: Post, at index: Int) -> [MediaItem] {
        let images = post.imageURLs.map { MediaItem(url: $0, postIndex: index, kind: .image) }
        let videos = PostParser.extractVideoURLs(from: post.text).map { url in
            MediaItem(url: url,
                      postIndex: index,
                      kind: url.pathExtension.lowercased() == "webm" ? .unsupportedVideo : .video)
        }
        return images + videos
    }
}

/// When the app downloads images ahead of time (先読み).
enum MediaPrefetchMode: String, CaseIterable, Identifiable {
    case off
    /// Images in the next couple of dozen posts while scrolling.
    case nearby
    /// Every image in a thread as soon as it opens, on Wi-Fi only.
    case allOnWiFi
    /// Every image in a thread as soon as it opens, on any connection.
    case all

    static let defaultsKey = "donguri.mediaPrefetch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "しない")
        case .nearby: String(localized: "近くの画像のみ")
        case .allOnWiFi: String(localized: "Wi-Fi時はすべて")
        case .all: String(localized: "常にすべて")
        }
    }

    static var current: MediaPrefetchMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MediaPrefetchMode.init(rawValue:)) ?? .nearby
    }
}
