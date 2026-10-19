//
//  Post.swift
//  Donguri
//
//  Created by John Connery on 6/15/26.
//

import Foundation

/// `Codable` so a whole thread can be written to disk for offline reading
/// (`SavedThreadStore`).
struct Post: Codable {
    let name: String
    let trip: String?
    let email: String
    let date: String
    let id: String?
    let text: String
    let threadTitle: String?

    /// Indices (into the thread's post array) of posts that reply to this one via `>>N`.
    let replies: [Int]?

    /// Image URLs found in `text`, shown as thumbnails below the post.
    let imageURLs: [URL]
}
