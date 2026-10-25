//
//  OrientationLock.swift
//  Donguri
//
//  Lets the video player turn the screen the way the YouTube app does: the
//  full-screen button rotates to landscape and the exit button back to
//  portrait, and each holds until the phone itself is turned to match.
//  Without the hold, leaving full screen while holding the phone sideways
//  rotated straight back.
//

import UIKit

enum OrientationLock {
    /// What the app allows right now (read by the app delegate).
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    private static var observer: NSObjectProtocol?

    static func rotate(to target: UIInterfaceOrientationMask) {
        mask = target
        startWatchingDevice()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // Every controller up the presentation chain re-reads what it allows.
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
    }

    /// Back to portrait when leaving the player, if it isn't already.
    static func returnToPortrait() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              scene.interfaceOrientation.isLandscape else {
            mask = .allButUpsideDown
            return
        }
        rotate(to: .portrait)
    }

    /// Once the phone is held the way the lock points, rotation is free
    /// again (so turning it back still enters or leaves full screen).
    private static func startWatchingDevice() {
        guard observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let device = UIDevice.current.orientation
                if mask == .portrait, device == .portrait {
                    mask = .allButUpsideDown
                } else if mask == .landscape, device.isLandscape {
                    mask = .allButUpsideDown
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
