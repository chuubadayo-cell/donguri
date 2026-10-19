//
//  ReadState.swift
//  Donguri
//
//  Created by John Connery on 8/17/26.
//

import Foundation

struct ReadState: Codable {
    var lastReadCount: Int
    var lastReadIndex: Int
    /// When the thread was last opened, so stale entries can be dropped.
    /// Optional because entries saved by older builds don't have it.
    var lastVisited: Date?
}
