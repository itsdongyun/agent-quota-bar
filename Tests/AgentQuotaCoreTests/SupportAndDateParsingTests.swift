import XCTest
@testable import AgentQuotaCore

final class SupportAndDateParsingTests: XCTestCase {
    func testDateParsingHandlesISO8601UnixAndJWT() {
        XCTAssertNotNil(DateParsing.parseISO8601("2026-11-17T06:00:00Z"))
        XCTAssertNotNil(DateParsing.parseISO8601("2026-11-17T06:00:00.123Z"))
        XCTAssertNil(DateParsing.parseISO8601("   "))

        let secDate = DateParsing.parseUnixTimestamp(1_700_000_000)
        let msDate = DateParsing.parseUnixTimestamp(1_700_000_000_000)
        XCTAssertEqual(secDate?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(msDate?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)

        // Base64URL payload: {"exp":1800000000}
        let payload = Data(#"{"exp":1800000000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        XCTAssertEqual(DateParsing.jwtExpiry(from: jwt)?.timeIntervalSince1970 ?? 0, 1_800_000_000, accuracy: 0.001)
    }

    func testAugmentedEnvironmentIncludesStandardPathsWithoutDuplicates() {
        let env = SystemSubprocessRunner.augmentedEnvironment(["PATH": "/custom/bin:/opt/homebrew/bin:/custom/bin"])
        let parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/custom/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertEqual(parts.filter { $0 == "/custom/bin" }.count, 1)
        XCTAssertEqual(parts.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testSubprocessRunnerTimeoutAndTaskCancellation() async {
        do {
            _ = try await SystemSubprocessRunner.shared.run(
                binary: "/bin/sleep",
                arguments: ["5"],
                environment: [:],
                currentDirectoryURL: nil,
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .timedOut(0.1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let task = Task {
            try await SystemSubprocessRunner.shared.run(
                binary: "/bin/sleep",
                arguments: ["5"],
                environment: [:],
                currentDirectoryURL: nil,
                timeout: 10
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSubprocessReturnsWhenGrandchildKeepsPipesOpen() async throws {
        let started = Date()
        let output = try await SystemSubprocessRunner().run(
            binary: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo done"],
            environment: [:],
            currentDirectoryURL: nil,
            timeout: 10
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSubprocessKillsProcessThatIgnoresSIGTERMAfterTimeout() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        do {
            _ = try await SystemSubprocessRunner().run(
                binary: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; while true; do sleep 1; done"],
                environment: [:],
                currentDirectoryURL: nil,
                timeout: 0.5
            )
            XCTFail("Expected timeout")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .timedOut(0.5))
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(pidText))
        var alive = true
        for _ in 0..<50 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid, 0) == 0
        }
        XCTAssertFalse(alive, "Process ignoring SIGTERM must be killed with SIGKILL")
    }
}
