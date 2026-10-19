//
//  MediaFrameRegistry.swift
//  Donguri
//
//  Where each post thumbnail is on screen, so the gallery can grow an image
//  out of the thumbnail that was tapped, and shrink it back into the right
//  one when it closes. Thumbnails report their frame as they lay out; the
//  gallery reads it when it opens and closes. Deliberately not observable:
//  nothing should redraw because a thumbnail moved.
//

import SwiftUI

final class MediaFrameRegistry {
    static let shared = MediaFrameRegistry()

    private var frames: [String: CGRect] = [:]

    func set(_ frame: CGRect, for id: String) {
        frames[id] = frame
    }

    /// Forgets the frame only if it's still the one this thumbnail
    /// reported; the same image can also be on screen in a reply preview.
    func remove(_ frame: CGRect, for id: String) {
        if frames[id] == frame { frames[id] = nil }
    }

    /// The thumbnail's frame in window coordinates, if it's on screen.
    func frame(for id: String) -> CGRect? {
        guard let frame = frames[id], frame.width > 1 else { return nil }
        let screen = UIScreen.main.bounds
        return screen.intersects(frame) ? frame : nil
    }
}

/// Holds the last reported frame without making the view redraw.
private final class FrameBox {
    var frame: CGRect = .zero
}

private struct MediaFrameReporter: ViewModifier {
    let id: String
    @State private var box = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                box.frame = frame
                MediaFrameRegistry.shared.set(frame, for: id)
            }
            .onDisappear {
                MediaFrameRegistry.shared.remove(box.frame, for: id)
            }
    }
}

extension View {
    func reportsMediaFrame(for id: String) -> some View {
        modifier(MediaFrameReporter(id: id))
    }
}
