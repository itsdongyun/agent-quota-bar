import Foundation

/// Fetches Antigravity usage via `agy -p "/usage" --output-format json` (zero LLM tokens consumed).
public actor AntigravityQuotaProvider: QuotaProvider {
    public nonisolated let providerID: ProviderID = .antigravity

    private let subprocess: SubprocessRunning
    private let environment: [String: String]
    private var inFlightTask: Task<ProviderQuotaSnapshot, Error>?

    public init(
        subprocess: SubprocessRunning = SystemSubprocessRunner.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.subprocess = subprocess
        self.environment = environment
    }

    public func checkConnectionStatus() async -> ProviderConnectionStatus {
        guard subprocess.resolveBinary("agy", environment: environment) != nil else {
            return .notInstalled
        }
        return .connected
    }

    public func fetchUsage() async throws -> ProviderQuotaSnapshot {
        if let inFlightTask {
            return try await inFlightTask.value
        }

        let task = Task<ProviderQuotaSnapshot, Error> {
            try await performFetch()
        }
        inFlightTask = task
        defer { inFlightTask = nil }
        return try await task.value
    }

    private func performFetch() async throws -> ProviderQuotaSnapshot {
        guard let binary = subprocess.resolveBinary("agy", environment: environment) else {
            throw QuotaProviderError.notInstalled
        }

        // Isolate cwd and stub browser launchers so `agy` never opens a browser window on auth errors.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-quota-bar-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var childEnv = SystemSubprocessRunner.augmentedEnvironment(environment)
        for cmd in ["open", "xdg-open"] {
            let stubURL = tempDir.appendingPathComponent(cmd)
            FileManager.default.createFile(
                atPath: stubURL.path,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        }
        childEnv["PATH"] = tempDir.path + ":" + (childEnv["PATH"] ?? "/usr/bin:/bin")
        childEnv["BROWSER"] = tempDir.appendingPathComponent("open").path

        let output = try await subprocess.run(
            binary: binary,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"],
            environment: childEnv,
            currentDirectoryURL: tempDir,
            timeout: 35
        )
        return try Self.parseUsageOutput(output)
    }

    // MARK: - Output Parsing (internal for unit testing)

    static func parseUsageOutput(
        _ output: SubprocessOutput,
        now: Date = Date()
    ) throws -> ProviderQuotaSnapshot {
        let combined = output.stdoutString + "\n" + output.stderrString
        let lower = combined.lowercased()
        if lower.contains("select login method") || lower.contains("not logged into antigravity") {
            throw QuotaProviderError.loginRequired
        }

        guard output.exitCode == 0 else {
            throw QuotaProviderError.executionFailed(.cliExited(.antigravity, output.exitCode))
        }

        guard let jsonData = extractJSONObjectData(from: output.stdout) else {
            throw QuotaProviderError.invalidResponse(.missingJSON(.antigravity))
        }

        let decoded: WirePrintResponse
        do {
            decoded = try JSONDecoder().decode(WirePrintResponse.self, from: jsonData)
        } catch {
            throw QuotaProviderError.invalidResponse(.invalidPayload(.antigravity))
        }

        if let status = decoded.status, status.uppercased() != "SUCCESS" {
            throw QuotaProviderError.executionFailed(.cliStatus(.antigravity, status))
        }

        var windows: [QuotaWindow] = []
        for group in decoded.command?.data?.groups ?? [] {
            let groupName = group.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Antigravity"
            for bucket in group.buckets ?? [] {
                guard let bucketID = bucket.id,
                      let remainingFraction = bucket.remaining_fraction
                else { continue }

                let rawWindow = bucket.window?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let cadence: QuotaCadence
                let cadenceLabel: String
                switch rawWindow {
                case "5h":
                    cadence = .fiveHour
                    cadenceLabel = "5h"
                case "weekly", "7d", nil, "":
                    cadence = .sevenDay
                    cadenceLabel = "7d"
                default:
                    cadence = .other
                    cadenceLabel = rawWindow ?? ""
                }
                let usedPercent = (1.0 - remainingFraction) * 100.0
                let resetDate = DateParsing.parseISO8601(bucket.reset_time)
                let shortGroup = Self.shortGroupName(groupName)

                windows.append(QuotaWindow(
                    id: "antigravity.\(bucketID)",
                    provider: .antigravity,
                    category: .modelSpecific,
                    cadence: cadence,
                    modelName: shortGroup,
                    label: cadenceLabel.isEmpty ? shortGroup : "\(shortGroup) (\(cadenceLabel))",
                    usedPercent: usedPercent,
                    resetsAt: resetDate
                ))
            }
        }

        return ProviderQuotaSnapshot(
            provider: .antigravity,
            planName: nil,
            accountLabel: nil,
            windows: windows,
            fetchedAt: now
        )
    }

    private static func shortGroupName(_ name: String) -> String {
        switch name {
        case "Gemini Models": return "Gemini"
        case "Claude and GPT models": return "Claude/GPT"
        default: return name
        }
    }

    private static func extractJSONObjectData(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else {
            return nil
        }
        let fullSpan = Data(text[firstBrace...lastBrace].utf8)
        if (try? JSONSerialization.jsonObject(with: fullSpan)) is [String: Any] {
            return fullSpan
        }
        // Fallback when warning lines before/after the JSON payload contain stray '{' or '}' characters.
        let starts = text.indices.filter { text[$0] == "{" }.prefix(16)
        let ends = text.indices.filter { text[$0] == "}" }.reversed().prefix(16)
        for start in starts {
            for end in ends where start <= end {
                let candidate = Data(text[start...end].utf8)
                if (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Wire Models

    private struct WirePrintResponse: Decodable {
        let status: String?
        let command: WireCommand?
    }

    private struct WireCommand: Decodable {
        let name: String?
        let data: WireCommandData?
    }

    private struct WireCommandData: Decodable {
        let groups: [WireGroup]?
    }

    private struct WireGroup: Decodable {
        let name: String?
        let buckets: [WireBucket]?
    }

    private struct WireBucket: Decodable {
        let id: String?
        let name: String?
        let window: String?
        let remaining_fraction: Double?
        let reset_time: String?
    }
}
