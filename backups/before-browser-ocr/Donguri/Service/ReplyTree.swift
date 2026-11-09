//
//  ReplyTree.swift
//  Donguri
//
//  Chance's tree mode for a thread: each post is placed under the post it
//  replies to (its first `>>N`), so a back-and-forth reads as one indented
//  conversation instead of being scattered through the thread.
//
//  Replies to the first post (>>1) stay at the top level: in a 5ch thread
//  almost everything answers >>1, and nesting all of it would just indent
//  the whole thread.
//

import Foundation

nonisolated struct ReplyTree: Sendable {
    /// Parent of each post (index into posts), or nil for top-level posts.
    let parent: [Int?]
    /// Children of each post, in thread order.
    let children: [[Int]]
    /// How many posts are nested below each post, at any depth.
    let descendantCount: [Int]

    static let empty = ReplyTree(parent: [], children: [], descendantCount: [])

    init(parent: [Int?], children: [[Int]], descendantCount: [Int]) {
        self.parent = parent
        self.children = children
        self.descendantCount = descendantCount
    }

    init(posts: [Post]) {
        let count = posts.count
        var parent = [Int?](repeating: nil, count: count)
        var children = [[Int]](repeating: [], count: count)

        for index in 1..<max(count, 1) where index < count {
            let text = posts[index].text
            guard text.contains("donguri://res/"),
                  let match = text.firstMatch(of: #/donguri://res/(\d+)/#),
                  let number = Int(match.1) else { continue }
            let target = number - 1
            // Only earlier posts, and not the first post.
            guard target >= 1, target < index else { continue }
            parent[index] = target
            children[target].append(index)
        }

        // Children always come after their parent, so one backwards pass
        // adds every subtree up.
        var descendants = [Int](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            if let p = parent[index] {
                descendants[p] += descendants[index] + 1
            }
        }

        self.parent = parent
        self.children = children
        self.descendantCount = descendants
    }

    /// Posts in tree order with their depth, skipping what's under a
    /// collapsed post.
    func flattened(collapsed: Set<Int>) -> (order: [Int], depth: [Int: Int]) {
        var order: [Int] = []
        order.reserveCapacity(parent.count)
        var depth: [Int: Int] = [:]
        var stack: [(index: Int, depth: Int)] = []

        for root in parent.indices.reversed() where parent[root] == nil {
            stack.append((root, 0))
        }
        while let next = stack.popLast() {
            order.append(next.index)
            depth[next.index] = next.depth
            guard !collapsed.contains(next.index) else { continue }
            for child in children[next.index].reversed() {
                stack.append((child, next.depth + 1))
            }
        }
        return (order, depth)
    }
}
