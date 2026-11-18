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

    /// How long to keep reading after the child exits. A grandchild that inherited stdout/stderr can hold
    /// the pipes open indefinitely, so the result must not wait for EOF alone.
    static let pipeDrainGrace: DispatchTimeInterval = .seconds(1)
    /// How long a process gets to exit after SIGTERM before it is sent SIGKILL.
    static let killEscalationDelay: DispatchTimeInterval = .seconds(2)

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
            var terminationRequested = false
            var stdoutData = Data()
            var stderrData = Data()
            var stdoutEOF = false
            var stderrEOF = false
            var exitStatus: Int32?
            var timeoutTimer: DispatchSourceTimer?
            var drainTimer: DispatchSourceTimer?
            /// Lives independently of `finished`: the result is reported right after SIGTERM,
            /// but the process still has to be killed if it ignores it.
            var killTimer: DispatchSourceTimer?
            var readHandles: [FileHandle] = []
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
                let (cont, handles, shouldReport) = lock.withLock {
                    () -> (CheckedContinuation<SubprocessOutput, Error>?, [FileHandle], Bool) in
                    if finished { return (nil, [], false) }
                    finished = true
                    timeoutTimer?.cancel()
                    timeoutTimer = nil
                    drainTimer?.cancel()
                    drainTimer = nil
                    let handles = readHandles
                    readHandles = []
                    if let continuation {
                        self.continuation = nil
                        return (continuation, handles, true)
                    }
                    self.pendingResult = result
                    return (nil, handles, true)
                }
                guard shouldReport else { return }
                for handle in handles {
                    handle.readabilityHandler = nil
                }
                cont?.resume(with: result)
            }

            func attachReader(_ handle: FileHandle, isStdout: Bool) {
                lock.withLock { readHandles.append(handle) }
                handle.readabilityHandler = { [self] handle in
                    let chunk = handle.availableData
                    let ready = lock.withLock { () -> Bool in
                        if chunk.isEmpty {
                            if isStdout { stdoutEOF = true } else { stderrEOF = true }
                        } else if isStdout {
                            stdoutData.append(chunk)
                        } else {
                            stderrData.append(chunk)
                        }
                        return exitStatus != nil && stdoutEOF && stderrEOF
                    }
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    }
                    if ready {
                        completeWithCapturedOutput()
                    }
                }
            }

            func processExited(status: Int32) {
                let (ready, alreadyFinished) = lock.withLock { () -> (Bool, Bool) in
                    exitStatus = status
                    return (stdoutEOF && stderrEOF, finished)
                }
                if alreadyFinished { return }
                if ready {
                    completeWithCapturedOutput()
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + SystemSubprocessRunner.pipeDrainGrace)
                timer.setEventHandler { [self] in
                    completeWithCapturedOutput()
                }
                let installed = lock.withLock { () -> Bool in
                    guard !finished else { return false }
                    drainTimer = timer
                    return true
                }
                if installed {
                    timer.resume()
                } else {
                    // A source must not be released while suspended: cancel, then resume so it can be disposed.
                    timer.cancel()
                    timer.resume()
                }
            }

            private func completeWithCapturedOutput() {
                let output = lock.withLock { () -> SubprocessOutput? in
                    guard let exitStatus else { return nil }
                    return SubprocessOutput(exitCode: exitStatus, stdout: stdoutData, stderr: stderrData)
                }
                if let output {
                    complete(.success(output))
                }
            }

            func terminateProcessWithEscalation(_ process: Process) {
                let shouldTerminate = lock.withLock { () -> Bool in
                    guard launched, !terminationRequested else { return false }
                    terminationRequested = true
                    return true
                }
                guard shouldTerminate, process.isRunning else { return }
                process.terminate()
                let pid = process.processIdentifier
                let killer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                killer.schedule(deadline: .now() + SystemSubprocessRunner.killEscalationDelay)
                killer.setEventHandler { [self] in
                    if process.isRunning, pid > 0 {
                        kill(pid, SIGKILL)
                    }
                    // Cancelling releases this handler, which breaks the state -> timer -> handler cycle.
                    let timer = lock.withLock { () -> DispatchSourceTimer? in
                        defer { killTimer = nil }
                        return killTimer
                    }
                    timer?.cancel()
                }
                lock.withLock { killTimer = killer }
                killer.resume()
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

                state.attachReader(stdoutPipe.fileHandleForReading, isStdout: true)
                state.attachReader(stderrPipe.fileHandleForReading, isStdout: false)

                process.terminationHandler = { proc in
                    state.processExited(status: proc.terminationStatus)
                }

                do {
                    try process.run()
                    // Close parent's write ends so EOF is delivered once every holder of the pipes exits.
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
                        // A source must not be released while suspended: cancel, then resume so it can be disposed.
                        timer.cancel()
                        timer.resume()
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
