//
//  FullSwipeBack.swift
//  Donguri
//
//  Swipe right anywhere on a screen to go back, as Chance does, instead of
//  only from the left edge.
//
//  iOS 26 has this built in (UINavigationController's content pop gesture),
//  and that is used when present. Earlier versions get a full-width pan that
//  drives the navigation controller's own interactive pop transition, so the
//  swipe tracks the finger and can be cancelled exactly like the edge swipe.
//

import SwiftUI
import UIKit
import WebKit

/// Put in the background of a navigation stack's root view.
struct FullSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.install()
    }

    final class Controller: UIViewController {
        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        func install() {
            guard let navigationController else { return }
            FullSwipeBackManager.shared.install(on: navigationController)
        }
    }
}

final class FullSwipeBackManager: NSObject, UIGestureRecognizerDelegate {
    static let shared = FullSwipeBackManager()

    private let controllers = NSHashTable<UINavigationController>.weakObjects()
    /// iOS 26's own recognizers, which follow the setting.
    private let systemRecognizers = NSHashTable<UIGestureRecognizer>.weakObjects()

    private static let systemKey = "interactiveContentPopGestureRecognizer"

    func install(on navigationController: UINavigationController) {
        guard !controllers.contains(navigationController) else { return }
        controllers.add(navigationController)

        if navigationController.responds(to: NSSelectorFromString(Self.systemKey)),
           let system = navigationController.value(forKey: Self.systemKey) as? UIGestureRecognizer {
            systemRecognizers.add(system)
            system.isEnabled = BehaviorSettings.shared.fullSwipeBack
            return
        }

        // The edge gesture's targets are the navigation controller's
        // interactive transition; a pan with the same targets drives it.
        guard let edge = navigationController.interactivePopGestureRecognizer,
              let targets = edge.value(forKey: "targets") else { return }
        let pan = UIPanGestureRecognizer()
        pan.setValue(targets, forKey: "targets")
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        navigationController.view.addGestureRecognizer(pan)
    }

    func settingDidChange() {
        for recognizer in systemRecognizers.allObjects {
            recognizer.isEnabled = BehaviorSettings.shared.fullSwipeBack
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard BehaviorSettings.shared.fullSwipeBack,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let navigationController = pan.view?.next as? UINavigationController,
              navigationController.viewControllers.count > 1,
              navigationController.transitionCoordinator == nil else { return false }
        let velocity = pan.velocity(in: pan.view)
        // Rightwards and mostly horizontal; vertical drags keep scrolling.
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.4
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Leave the dictionary popup (a web view), sliders and anything that
        // scrolls sideways to themselves.
        var view = touch.view
        while let current = view {
            if current is WKWebView || current is UISlider { return false }
            if let scroll = current as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > 0 {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
