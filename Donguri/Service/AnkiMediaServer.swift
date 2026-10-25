//
//  AnkiMediaServer.swift
//  Donguri
//
//  AnkiMobile's add-note link can't carry media, but when a field holds
//  nothing but a link to an image or sound file, AnkiMobile downloads it
//  and stores it as a proper media file. So clips and pictures for cards
//  are served from a tiny web server inside いろは, on the phone's loopback
//  interface only, for the minute AnkiMobile needs to fetch them. (Hoshi
//  Reader does the same with its LocalFileServer.)
//

import Foundation
import Network
import UIKit

@MainActor
final class AnkiMediaServer {
    static let shared = AnkiMediaServer()

    private var listener: NWListener?
    private var port: UInt16?
    /// Published name → file.
    private var files: [String: URL] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopTask: Task<Void, Never>?

    private init() {}

    /// A link AnkiMobile can download `file` from, or nil if the server
    /// can't start.
    func link(for file: URL) async -> String? {
        guard let port = await start() else { return nil }
        let name = "iroha_\(UUID().uuidString.prefix(8).lowercased()).\(file.pathExtension.lowercased())"
        files[name] = file
        return "http://localhost:\(port)/\(name)"
    }

    /// Keeps the server reachable while AnkiMobile is in front and
    /// downloading, then lets it go.
    func keepAliveForHandoff() {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Anki media") { [weak self] in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func start() async -> UInt16? {
        if let port, listener != nil { return port }
        let parameters = NWParameters.tcp
        // Loopback only: nothing on the network can reach it.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        guard ready, let port = listener.port?.rawValue else {
            listener.cancel()
            self.listener = nil
            return nil
        }
        self.port = port
        return port
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        files.removeAll()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let name = String(path.split(separator: "?").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let isHead = request.hasPrefix("HEAD")
                guard let file = self.files[name], let body = try? Data(contentsOf: file) else {
                    self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8), head: isHead)
                    return
                }
                self.respond(connection, status: "200 OK", type: Self.mimeType(file.pathExtension), body: body, head: isHead)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data, head: Bool) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "gif": "image/gif"
        case "png": "image/png"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }
}

/// True the first time only; for continuations fed by repeating callbacks.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
