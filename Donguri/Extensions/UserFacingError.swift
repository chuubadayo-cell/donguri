//
//  UserFacingError.swift
//  Donguri
//
//  One wording for network failures everywhere, instead of the raw error
//  ("Error Domain=NSURLErrorDomain Code=-1009 …") each screen used to show.
//

import Foundation

nonisolated enum UserFacingError {
    static func message(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "インターネットに接続されていません")
            case .timedOut:
                return String(localized: "接続がタイムアウトしました。しばらくしてからもう一度お試しください。")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "サーバーに接続できませんでした")
            case .badServerResponse:
                return String(localized: "サーバーから正しい応答がありませんでした。混雑しているか、一時的に止まっている可能性があります。")
            case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse:
                return String(localized: "受け取ったデータを読み取れませんでした")
            case .badURL, .unsupportedURL:
                return String(localized: "URLが正しくありません")
            case .cancelled:
                return String(localized: "キャンセルされました")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return String(localized: "安全な接続を確立できませんでした")
            default:
                break
            }
        }
        if let error = error as? DatCache.FetchError, error == .notFound {
            return String(localized: "スレが見つかりませんでした（削除されたか、dat落ちしています）")
        }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return String(localized: "エラーが発生しました: \(error.localizedDescription)")
    }

    /// A cancelled request (the screen went away, or a newer load started)
    /// isn't worth telling anyone about.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}
