//
//  Thread.swift
//  Donguri
//
//  Created by John Connery on 6/15/26.
//

import Foundation

/// `nonisolated` so `ThreadService` can parse subject.txt off the main actor.
nonisolated struct Thread: Identifiable {
    let id: Int
    let title: String?
    let responseCount: Int
}
