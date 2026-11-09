//
//  Post.swift
//  Donguri
//
//  Created by John Connery on 6/15/26.
//

import Foundation

/// `Codable` so a whole thread can be written to disk for offline reading
/// (`SavedThreadStore`), and `nonisolated` so `PostParser` can build posts on
/// a background thread.
nonisolated struct Post: Codable {
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

    /// The post was deleted on the server (its dat line reads あぼーん) or its
    /// line couldn't be read. It is kept as a placeholder, because every
    /// `>>N` link and reply index counts posts by position.
    var isDeleted: Bool? = nil

    /// A stand-in for a post that can't be shown.
    static func deleted(date: String = "") -> Post {
        Post(name: "", trip: nil, email: "", date: date, id: nil, text: "",
             threadTitle: nil, replies: nil, imageURLs: [], isDeleted: true)
    }
}
