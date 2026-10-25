//
//  SafariUserAgent.swift
//  Donguri
//
//  The user agent the app's web views present: exactly what Safari on this
//  iPhone sends. Google's sign-in and YouTube both treat anything else as
//  an embedded browser. Since iOS 26, Safari freezes the OS version in its
//  user agent at 18_6 and reports the real version only as "Version/";
//  a UA claiming "iPhone OS 26_0" is one no real Safari sends.
//

import UIKit

nonisolated enum SafariUserAgent {
    static let mobile: String = {
        let parts = ProcessInfo.processInfo.operatingSystemVersion
        let major = parts.majorVersion
        let minor = parts.minorVersion
        let osToken: String
        if major >= 26 {
            osToken = "18_6"
        } else {
            osToken = parts.patchVersion > 0 ? "\(major)_\(minor)_\(parts.patchVersion)" : "\(major)_\(minor)"
        }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }()
}
