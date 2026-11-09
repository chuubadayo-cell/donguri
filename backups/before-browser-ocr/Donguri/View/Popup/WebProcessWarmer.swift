//
//  WebProcessWarmer.swift
//  Donguri
//
//  Keeps WebKit's web content process running, so the first dictionary
//  popup in a thread doesn't wait for it to launch.
//
//  Hoshi Reader never has this problem: its reader is itself a web view, so
//  the process is always up. Here posts are native text, so once the last
//  popup closes no web view is left and iOS may stop the process; the next
//  tap then pays for starting it again. One tiny, never-shown web view that
//  has already loaded the popup's script and stylesheet avoids that.
//

import UIKit
import WebKit

enum WebProcessWarmer {
    private static var webView: WKWebView?

    static func warm() {
        guard webView == nil else { return }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isHidden = true
        view.loadHTMLString("""
            <!DOCTYPE html>
            <html><head>
            <link rel="stylesheet" href="popup.css">
            <script src="selection.js"></script>
            <script src="popup.js"></script>
            </head><body></body></html>
            """, baseURL: Bundle.main.resourceURL)
        webView = view
    }
}
