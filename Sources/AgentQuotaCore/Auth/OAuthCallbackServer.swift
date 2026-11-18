import Foundation
import Network

/// One-shot localhost HTTP listener that receives the browser's OAuth redirect (`/callback?code=…&state=…`).
///
/// Accepts connections only on the loopback interface (IPv4 and IPv6, since browsers may resolve `localhost`
/// to `::1`), so other machines cannot reach it or send a fake callback.
public final class OAuthCallbackServer: @unchecked Sendable {
    public struct Pages: Sendable {
        public let successHTML: String
        public let failureHTML: String

        public init(successHTML: String, failureHTML: String) {
            self.successHTML = successHTML
            self.failureHTML = failureHTML
        }
    }

    private let queue = DispatchQueue(label: "com.agentquotabar.app.oauth-callback")
    private let pages: Pages
    private var listener: NWListener?
    private var onCallback: (@Sendable ([String: String]) -> Void)?
    private var didDeliver = false

    public init(pages: Pages) {
        self.pages = pages
    }

    deinit {
        listener?.cancel()
    }

    /// Binds the first free port. `onCallback` runs once, on a background queue, with the callback's query items.
    public func start(ports: [UInt16], onCallback: @escaping @Sendable ([String: String]) -> Void) async -> UInt16? {
        queue.sync {
            self.onCallback = onCallback
            self.didDeliver = false
        }
        for port in ports {
            if await listen(on: port) {
                return port
            }
        }
        return nil
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            onCallback = nil
        }
    }

    private func listen(on port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: nwPort) else { return false }

        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(true)
                case .waiting, .failed, .cancelled:
                    // A port in use leaves the listener waiting forever; move on to the next port.
                    once.resume(false)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { once.resume(false) }
        }

        if ready {
            queue.sync { self.listener = listener }
            AppLogger.app.info("OAuth callback server listening on port \(port, privacy: .public)")
        } else {
            listener.cancel()
        }
        return ready
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let query = Self.parseQuery(fromRequest: request)
            let isCallback = query["code"] != nil || query["error"] != nil
            let response = isCallback
                ? Self.httpResponse(status: "200 OK", body: query["code"] != nil ? self.pages.successHTML : self.pages.failureHTML)
                : Self.httpResponse(status: "404 Not Found", body: "")
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            // Runs on `queue`, so delivery state needs no extra locking.
            if isCallback, !self.didDeliver, let onCallback = self.onCallback {
                self.didDeliver = true
                onCallback(query)
            }
        }
    }

    static func parseQuery(fromRequest request: String) -> [String: String] {
        guard let requestLine = request.split(separator: "\r\n").first else { return [:] }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: String(parts[1])),
              components.path == ClaudeOAuthClient.Config.callbackPath
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { result[item.name] = value }
        }
        return result
    }

    private static func httpResponse(status: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

/// Resumes a continuation at most once even when several listener states race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
