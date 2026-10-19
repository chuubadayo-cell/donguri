//
//  MediaFrameRegistry.swift
//  Donguri
//
//  Where each post thumbnail is on screen, so the gallery can grow an image
//  out of the thumbnail that was tapped, and shrink it back into the right
//  one when it closes.
//
//  Each thumbnail carries an invisible anchor view, and the registry keeps a
//  weak reference to it. Frames are only worked out when the gallery asks,
//  so scrolling does no extra work at all (an earlier version recorded every
//  thumbnail's frame on every frame of scrolling).
//

import SwiftUI
import UIKit

final class MediaFrameRegistry {
    static let shared = MediaFrameRegistry()

    private let anchors = NSMapTable<NSString, UIView>.strongToWeakObjects()

    func register(_ view: UIView, for id: String) {
        anchors.setObject(view, forKey: id as NSString)
    }

    /// Forgets the anchor only if it's still this one; the same image can
    /// also be on screen in a reply preview.
    func unregister(_ view: UIView, for id: String) {
        if anchors.object(forKey: id as NSString) === view {
            anchors.removeObject(forKey: id as NSString)
        }
    }

    /// The thumbnail's frame in window coordinates, if it's on screen.
    func frame(for id: String) -> CGRect? {
        guard let view = anchors.object(forKey: id as NSString),
              let window = view.window, !view.isHiddenOnScreen else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        guard frame.width > 1, window.bounds.intersects(frame) else { return nil }
        return frame
    }
}

private extension UIView {
    /// Hidden itself or inside something hidden (a background browser tab).
    var isHiddenOnScreen: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return true }
            view = current.superview
        }
        return false
    }
}

/// The invisible view a thumbnail registers.
private struct MediaFrameAnchor: UIViewRepresentable {
    let id: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        MediaFrameRegistry.shared.register(view, for: id)
        context.coordinator.id = id
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.id != id {
            MediaFrameRegistry.shared.unregister(view, for: context.coordinator.id)
            context.coordinator.id = id
        }
        MediaFrameRegistry.shared.register(view, for: id)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        MediaFrameRegistry.shared.unregister(view, for: coordinator.id)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var id = ""
    }
}

extension View {
    func reportsMediaFrame(for id: String) -> some View {
        background(MediaFrameAnchor(id: id))
    }
}
