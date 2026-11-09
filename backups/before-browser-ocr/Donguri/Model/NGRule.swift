//
//  NGRule.swift
//  Donguri
//
//  Created by John Connery on 9/3/26.
//

import Foundation

/// One NG (あぼーん) rule. 5ch clients traditionally filter on the post body
/// (NGワード), the poster's ID (NGID) or their name/tripcode (NG名前).
struct NGRule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case word
        case id
        case name
        /// Hides threads from board lists by title.
        case threadTitle

        var id: String { rawValue }

        /// `String(localized:)` rather than a bare literal — this is a plain
        /// `String` property, so nothing would look it up otherwise.
        var label: String {
            switch self {
            case .word: String(localized: "NGワード")
            case .id: String(localized: "NG ID")
            case .name: String(localized: "NG名前")
            case .threadTitle: String(localized: "NGスレタイ")
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var pattern: String
}

/// A thread hidden from its board's list (スレの非表示).
struct HiddenThread: Codable, Identifiable, Hashable {
    var boardURL: String
    var threadId: Int
    var title: String
    var hiddenAt: Date = .now

    var id: String { ReadStateStore.key(boardURL: boardURL, threadId: threadId) }
}
