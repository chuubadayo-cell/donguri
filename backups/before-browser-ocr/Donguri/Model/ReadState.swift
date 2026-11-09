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
    /// The post at the top of the screen when the thread was left, so
    /// coming back (or switching tabs) lands exactly there. Optional for
    /// entries saved by older builds.
    var lastTopIndex: Int? = nil
}
