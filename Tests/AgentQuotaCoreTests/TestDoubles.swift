import Foundation
@testable import AgentQuotaCore

final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(URLRequest) throws -> HTTPResponseData]
    private(set) var recordedRequests: [URLRequest] = []

    init(handlers: [(URLRequest) throws -> HTTPResponseData]) {
        self.handlers = handlers
    }

    convenience init(response: HTTPResponseData) {
        self.init(handlers: [{ _ in response }])
    }

    func perform(_ request: URLRequest) async throws -> HTTPResponseData {
        let handler = lock.withLock { () -> ((URLRequest) throws -> HTTPResponseData) in
            recordedRequests.append(request)
            if handlers.count > 1 {
                return handlers.removeFirst()
            }
            return handlers[0]
        }
        return try handler(request)
    }
}

struct MockSubprocessRunner: SubprocessRunning {
    var resolvedPaths: [String: String]
    var handler: @Sendable (String, [String]) async throws -> SubprocessOutput

    init(
        resolvedPaths: [String: String] = [:],
        handler: @escaping @Sendable (String, [String]) async throws -> SubprocessOutput = { _, _ in
            SubprocessOutput(exitCode: 0, stdout: Data(), stderr: Data())
        }
    ) {
        self.resolvedPaths = resolvedPaths
        self.handler = handler
    }

    func resolveBinary(_ name: String, environment: [String: String]) -> String? {
        resolvedPaths[name]
    }

    func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async throws -> SubprocessOutput {
        try await handler(binary, arguments)
    }
}

final class InMemorySettingsStore: QuotaSettingsStoring, @unchecked Sendable {
    var stored: QuotaSettings

    init(stored: QuotaSettings = QuotaSettings()) {
        self.stored = stored
    }

    func load() -> QuotaSettings { stored }
    func save(_ settings: QuotaSettings) { stored = settings }
}

final class InMemorySnapshotStore: QuotaSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    var stored: [ProviderID: ProviderQuotaSnapshot]

    init(stored: [ProviderID: ProviderQuotaSnapshot] = [:]) {
        self.stored = stored
    }

    func load() -> [ProviderID: ProviderQuotaSnapshot] {
        lock.withLock { stored }
    }

    func save(_ snapshots: [ProviderID: ProviderQuotaSnapshot]) {
        lock.withLock { stored = snapshots }
    }
}
