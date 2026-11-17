import Darwin
import Foundation

/// Output captured from executing a local CLI command.
public struct SubprocessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum SubprocessError: Error, Sendable, Equatable {
    case binaryNotFound(String)
    case timedOut(TimeInterval)
    case launchFailed(String)
}

/// Abstraction over subprocess invocation and CLI binary discovery.
public protocol SubprocessRunning: Sendable {
    func resolveBinary(_ name: String, environment: [String: String]) -> String?
    func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async throws -> SubprocessOutput
}

/// Default Foundation `Process` runner that searches standard macOS + user CLI paths.
public struct SystemSubprocessRunner: SubprocessRunning {
    public static let shared = SystemSubprocessRunner()

    public init() {}

    private static func standardSearchPaths(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    /// Returns a copy of `environment` whose `PATH` includes standard user/Homebrew CLI directories.
    public static func augmentedEnvironment(_ environment: [String: String]) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var searchPaths: [String] = []
        if let envPath = environment["PATH"] {
            searchPaths.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        searchPaths.append(contentsOf: standardSearchPaths(home: home))

        var seen = Set<String>()
        let merged = searchPaths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        var updated = environment
        updated["PATH"] = merged
        return updated
    }

    public func resolveBinary(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fileManager = FileManager.default
        if name.contains("/"), fileManager.isExecutableFile(atPath: name) {
            return name
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        var searchPaths: [String] = []
        if let envPath = environment["PATH"] {
            searchPaths.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        searchPaths.append(contentsOf: Self.standardSearchPaths(home: home))

        var seen = Set<String>()
        for dir in searchPaths where !dir.isEmpty && seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> SubprocessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class RunState: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var launched = false
            var stdoutData = Data()
            var stderrData = Data()
            var timeoutTimer: DispatchSourceTimer?
            var killTimer: DispatchSourceTimer?
            var continuation: CheckedContinuation<SubprocessOutput, Error>?
            var pendingResult: Result<SubprocessOutput, Error>?

            func attachContinuation(_ cont: CheckedContinuation<SubprocessOutput, Error>) {
                let pending = lock.withLock { () -> Result<SubprocessOutput, Error>? in
                    if let pendingResult {
                        self.pendingResult = nil
                        return pendingResult
                    }
                    self.continuation = cont
                    return nil
                }
                if let pending {
                    cont.resume(with: pending)
                }
            }

            func complete(_ result: Result<SubprocessOutput, Error>) {
                let cont = lock.withLock { () -> CheckedContinuation<SubprocessOutput, Error>? in
                    if finished { return nil }
                    finished = true
                    timeoutTimer?.cancel()
                    timeoutTimer = nil
                    killTimer?.cancel()
                    killTimer = nil
                    if let continuation {
                        self.continuation = nil
                        return continuation
                    }
                    self.pendingResult = result
                    return nil
                }
                cont?.resume(with: result)
            }

            func terminateProcessWithEscalation(_ process: Process) {
                let shouldTerminate = lock.withLock { launched && !finished }
                guard shouldTerminate else { return }
                if process.isRunning {
                    process.terminate()
                    let pid = process.processIdentifier
                    let killer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    killer.schedule(deadline: .now() + .seconds(2))
                    killer.setEventHandler {
                        if process.isRunning, pid > 0 {
                            kill(pid, SIGKILL)
                        }
                    }
                    let installed = lock.withLock { () -> Bool in
                        guard !finished else { return false }
                        killTimer?.cancel()
                        killTimer = killer
                        return true
                    }
                    if installed {
                        killer.resume()
                    } else {
                        killer.cancel()
                    }
                }
            }
        }

        let state = RunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.attachContinuation(continuation)

                if Task.isCancelled {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    state.complete(.failure(CancellationError()))
                    return
                }

                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    state.lock.withLock { state.stdoutData = data }
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    state.lock.withLock { state.stderrData = data }
                    group.leave()
                }

                process.terminationHandler = { proc in
                    group.notify(queue: DispatchQueue.global(qos: .utility)) {
                        let output = state.lock.withLock {
                            SubprocessOutput(
                                exitCode: proc.terminationStatus,
                                stdout: state.stdoutData,
                                stderr: state.stderrData
                            )
                        }
                        state.complete(.success(output))
                    }
                }

                do {
                    try process.run()
                    // Close parent's write ends so EOF is delivered strictly when child exits.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()

                    let shouldCancelImmediately = state.lock.withLock { () -> Bool in
                        state.launched = true
                        return state.finished || Task.isCancelled
                    }
                    if shouldCancelImmediately {
                        state.terminateProcessWithEscalation(process)
                        state.complete(.failure(CancellationError()))
                        return
                    }

                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler {
                        state.terminateProcessWithEscalation(process)
                        state.complete(.failure(SubprocessError.timedOut(timeout)))
                    }
                    let installed = state.lock.withLock { () -> Bool in
                        guard !state.finished else { return false }
                        state.timeoutTimer = timer
                        return true
                    }
                    if installed {
                        timer.resume()
                    } else {
                        timer.cancel()
                    }
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    state.complete(.failure(SubprocessError.launchFailed(error.localizedDescription)))
                }
            }
        } onCancel: {
            state.terminateProcessWithEscalation(process)
            state.complete(.failure(CancellationError()))
        }
    }
}
