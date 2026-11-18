import XCTest
@testable import AgentQuotaCore

final class ProviderParsingTests: XCTestCase {
    func testClaudeParsesFiveHourAndSevenDayWindowsOnly() throws {
        let json = """
        {
          "five_hour": { "utilization": 18.0, "resets_at": "2026-11-17T06:00:00Z" },
          "seven_day": { "utilization": 42.0, "resets_at": "2026-11-21T00:00:00Z" },
          "seven_day_sonnet": { "utilization": 25.0, "resets_at": "2026-11-21T00:00:00Z" },
          "seven_day_opus": { "utilization": 30.0, "resets_at": "2026-11-21T00:00:00Z" },
          "limits": [
            {
              "kind": "weekly_scoped",
              "utilization": 60.0,
              "resets_at": "2026-11-21T00:00:00Z",
              "scope": { "model": { "display_name": "Sonnet" } }
            }
          ]
        }
        """
        let response = HTTPResponseData(data: Data(json.utf8), statusCode: 200)
        let snapshot = try ClaudeQuotaProvider.parseUsageResponse(response, planName: "Pro")

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.id), ["claude.5h", "claude.7d"])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 18.0)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 42.0)
    }

    func testClaudeCredentialPayloadAndRateLimitError() {
        let credJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-test",
            "refreshToken": "sk-ant-ort01-refresh",
            "expiresAt": 1794897454000
          }
        }
        """
        let creds = ClaudeQuotaProvider.parseCredentialPayload(Data(credJSON.utf8))
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-test")
        XCTAssertEqual(creds?.refreshToken, "sk-ant-ort01-refresh")
        XCTAssertNotNil(creds?.expiresAt)

        let rateLimitResponse = HTTPResponseData(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "120"]
        )
        XCTAssertThrowsError(try ClaudeQuotaProvider.parseUsageResponse(rateLimitResponse)) { error in
            guard case .rateLimited(let date) = error as? QuotaProviderError else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertNotNil(date)
        }
    }

    func testCodexParsesLiveWhamUsageAndAdditionalModelLimits() throws {
        let json = """
        {
          "plan_type": "plus",
          "email": "user@example.com",
          "rate_limit": {
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 18000,
              "reset_at": 1794897454
            },
            "secondary_window": {
              "used_percent": 94,
              "limit_window_seconds": 604800,
              "reset_at": 1794920759
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "Codex-Spark",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 15,
                  "limit_window_seconds": 604800,
                  "reset_at": 1794920759
                }
              }
            }
          ]
        }
        """
        let response = HTTPResponseData(data: Data(json.utf8), statusCode: 200)
        let snapshot = try CodexQuotaProvider.parseUsageResponse(response)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].category, .fiveHour)
        XCTAssertEqual(snapshot.windows[1].category, .sevenDay)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 94)
        XCTAssertEqual(snapshot.windows[2].category, .modelSpecific)
        XCTAssertEqual(snapshot.windows[2].modelName, "Codex-Spark")
    }

    func testCodexRefreshesOn401() async throws {
        let refreshedJSON = """
        { "access_token": "new-access", "refresh_token": "new-refresh" }
        """
        let usageJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1794897454 }
          }
        }
        """
        let transport = MockHTTPTransport(handlers: [
            { _ in HTTPResponseData(data: Data(), statusCode: 401) },
            { _ in HTTPResponseData(data: Data(refreshedJSON.utf8), statusCode: 200) },
            { req in
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return HTTPResponseData(data: Data(usageJSON.utf8), statusCode: 200)
            },
        ])
        let provider = CodexQuotaProvider(
            transport: transport,
            subprocess: MockSubprocessRunner(resolvedPaths: ["codex": "/usr/local/bin/codex"]),
            credentialReader: {
                CodexQuotaProvider.Credentials(accessToken: "old-access", refreshToken: "rt-1", accountID: "acct-1")
            }
        )

        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 10)
        XCTAssertEqual(transport.recordedRequests.count, 3)
    }

    func testAntigravityParsesPrintUsageJSON() throws {
        let json = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.64,
                      "reset_time": "2026-11-20T23:15:07Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.80,
                      "reset_time": "2026-11-17T02:58:12Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.86,
                      "reset_time": "2026-11-20T23:58:53Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let output = SubprocessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        let snapshot = try AntigravityQuotaProvider.parseUsageOutput(output)

        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].id, "antigravity.gemini-weekly")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 36.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].cadence, .sevenDay)
        XCTAssertEqual(snapshot.windows[1].cadence, .fiveHour)
        XCTAssertEqual(snapshot.windows[2].modelName, "Claude/GPT")
    }

    func testCodexResetAnnouncementActiveVsConfirmed() {
        let watchJSON = """
        {
          "latest_alert": {
            "id": "1",
            "kind": "watch",
            "state": "active",
            "summary": "Reset coming soon",
            "window": {
              "label": "within an hour",
              "end_at": "2026-11-17T12:00:00Z"
            }
          }
        }
        """
        let now = DateParsing.parseISO8601("2026-11-17T11:30:00Z")!
        let watch = CodexResetAnnouncementService.parseForecast(Data(watchJSON.utf8))
        XCTAssertTrue(watch?.isActive(at: now) == true)

        let confirmedJSON = """
        {
          "latest_alert": {
            "id": "2",
            "kind": "reset",
            "state": "confirmed",
            "summary": "Reset observed"
          }
        }
        """
        let confirmed = CodexResetAnnouncementService.parseForecast(Data(confirmedJSON.utf8))
        XCTAssertFalse(confirmed?.isActive(at: now) == true)
    }

    func testClaudePreservesRotatedRefreshTokenWithin30SecondsOfExpiryAndCoalesces() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var refreshCalls = 0
            var usageCalls = 0
        }
        let counter = Counter()
        let usageJSON = #"{"five_hour":{"utilization":22.0,"resets_at":"2026-11-17T06:00:00Z"}}"#
        let transport = MockHTTPTransport(handlers: [
            { req in
                if req.url?.path.contains("oauth/token") == true {
                    let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                    let callIndex = counter.lock.withLock { () -> Int in
                        counter.refreshCalls += 1
                        return counter.refreshCalls
                    }
                    if callIndex == 1 {
                        XCTAssertTrue(body.contains("rt-initial"))
                        return HTTPResponseData(
                            data: Data(#"{"access_token":"at-rotated-1","refresh_token":"rt-rotated-1","expires_in":15}"#.utf8),
                            statusCode: 200
                        )
                    } else {
                        XCTAssertTrue(body.contains("rt-rotated-1"), "Expected rotated refresh token, got body: \(body)")
                        return HTTPResponseData(
                            data: Data(#"{"access_token":"at-rotated-2","refresh_token":"rt-rotated-2","expires_in":3600}"#.utf8),
                            statusCode: 200
                        )
                    }
                }
                counter.lock.withLock { counter.usageCalls += 1 }
                return HTTPResponseData(data: Data(usageJSON.utf8), statusCode: 200)
            },
        ])
        let cliOK = #"{"loggedIn":true,"email":"a@b.com","subscriptionType":"pro"}"#
        let subprocess = MockSubprocessRunner(
            resolvedPaths: ["claude": "/usr/local/bin/claude"],
            handler: { _, _ in SubprocessOutput(exitCode: 0, stdout: Data(cliOK.utf8), stderr: Data()) }
        )
        let missingStatusLine = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        let initialExpiry = Date().addingTimeInterval(10)
        let provider = ClaudeQuotaProvider(
            transport: transport,
            subprocess: subprocess,
            credentialReader: {
                .found(ClaudeQuotaProvider.Credentials(
                    accessToken: "at-initial",
                    refreshToken: "rt-initial",
                    expiresAt: initialExpiry
                ))
            },
            statusLineCacheURL: missingStatusLine,
            cooldownStore: InMemoryRateLimitCooldownStore()
        )

        // First fetch rotates refresh token to rt-rotated-1 with expires_in = 15s (< 30s).
        _ = try await provider.fetchUsage()
        // Second fetch (also coalesced concurrently) must use rt-rotated-1, NOT disk rt-initial.
        async let first = provider.fetchUsage()
        async let second = provider.fetchUsage()
        let snapshots = try await [first, second]
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(counter.refreshCalls, 2)
    }

    func testClaudeDoesNotCacheLoggedOutCLIStatusAndMaps429OnRefresh() async throws {
        final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var loggedIn = false
        }
        let flag = Flag()
        let subprocess = MockSubprocessRunner(
            resolvedPaths: ["claude": "/usr/local/bin/claude"],
            handler: { _, _ in
                let isLoggedIn = flag.lock.withLock { flag.loggedIn }
                let json = isLoggedIn ? #"{"loggedIn":true}"# : #"{"loggedIn":false}"#
                return SubprocessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
            }
        )
        let transport = MockHTTPTransport(handlers: [
            { req in
                if req.url?.path.contains("oauth/token") == true {
                    return HTTPResponseData(data: Data(), statusCode: 429, headers: ["Retry-After": "45"])
                }
                return HTTPResponseData(data: Data(), statusCode: 401)
            },
        ])
        let missingStatusLine = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        let provider = ClaudeQuotaProvider(
            transport: transport,
            subprocess: subprocess,
            credentialReader: {
                .found(ClaudeQuotaProvider.Credentials(
                    accessToken: "expired-at",
                    refreshToken: "rt-1",
                    expiresAt: Date().addingTimeInterval(-10)
                ))
            },
            statusLineCacheURL: missingStatusLine,
            cooldownStore: InMemoryRateLimitCooldownStore()
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected loginRequired")
        } catch let error as QuotaProviderError {
            XCTAssertEqual(error, .loginRequired)
        }

        // Simulate user logging in via CLI; cachedCLIStatus must not remain stuck at false.
        flag.lock.withLock { flag.loggedIn = true }
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected rateLimited")
        } catch let error as QuotaProviderError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertNotNil(retryAfter)
        }
    }

    func testClaudeUsesFreshStatusLineCacheWithoutHTTPCall() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let statusLineURL = tempDir.appendingPathComponent("statusline-rate-limits.json")
        let cacheJSON = """
        {
          "updated_at": \(now.timeIntervalSince1970 - 60),
          "five_hour": { "used_percentage": 64, "resets_at": \(now.timeIntervalSince1970 + 3600) },
          "seven_day": { "used_percentage": 22, "resets_at": \(now.timeIntervalSince1970 + 86400) }
        }
        """
        try Data(cacheJSON.utf8).write(to: statusLineURL)

        let transport = MockHTTPTransport(handlers: [
            { _ in
                XCTFail("Should not hit OAuth HTTP endpoint when statusLine cache is fresh")
                return HTTPResponseData(data: Data(), statusCode: 500)
            },
        ])
        let cliOK = #"{"loggedIn":true,"email":"a@b.com","subscriptionType":"max"}"#
        let subprocess = MockSubprocessRunner(
            resolvedPaths: ["claude": "/usr/local/bin/claude"],
            handler: { _, _ in SubprocessOutput(exitCode: 0, stdout: Data(cliOK.utf8), stderr: Data()) }
        )
        let provider = ClaudeQuotaProvider(
            transport: transport,
            subprocess: subprocess,
            credentialReader: { .notFound },
            statusLineCacheURL: statusLineURL,
            cooldownStore: InMemoryRateLimitCooldownStore(),
            nowProvider: { now }
        )

        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.windows.map(\.id), ["claude.5h", "claude.7d"])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 64)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 22)
        XCTAssertEqual(transport.recordedRequests.count, 0)
    }

    func testClaudeFallsBackToHTTPWhenStatusLineStaleAndEnforces429Cooldown() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let statusLineURL = tempDir.appendingPathComponent("statusline-rate-limits.json")
        let staleJSON = """
        {
          "updated_at": \(now.timeIntervalSince1970 - 3600),
          "five_hour": { "used_percentage": 10, "resets_at": \(now.timeIntervalSince1970 + 3600) }
        }
        """
        try Data(staleJSON.utf8).write(to: statusLineURL)

        let transport = MockHTTPTransport(handlers: [
            { _ in HTTPResponseData(data: Data(), statusCode: 429) },
        ])
        let cliOK = #"{"loggedIn":true,"email":"a@b.com","subscriptionType":"pro"}"#
        let subprocess = MockSubprocessRunner(
            resolvedPaths: ["claude": "/usr/local/bin/claude"],
            handler: { _, _ in SubprocessOutput(exitCode: 0, stdout: Data(cliOK.utf8), stderr: Data()) }
        )
        let cooldownStore = InMemoryRateLimitCooldownStore()
        let provider = ClaudeQuotaProvider(
            transport: transport,
            subprocess: subprocess,
            credentialReader: {
                .found(ClaudeQuotaProvider.Credentials(
                    accessToken: "at-valid",
                    refreshToken: nil,
                    expiresAt: now.addingTimeInterval(3600)
                ))
            },
            statusLineCacheURL: statusLineURL,
            cooldownStore: cooldownStore,
            nowProvider: { now }
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected rateLimited")
        } catch let error as QuotaProviderError {
            guard case let .rateLimited(retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertNotNil(retryAfter)
        }
        XCTAssertEqual(transport.recordedRequests.count, 1)

        // Second attempt while in cooldown must NOT send another HTTP request.
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected rateLimited during cooldown")
        } catch let error as QuotaProviderError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        }
        XCTAssertEqual(transport.recordedRequests.count, 1)
    }

    func testCodexExternalCredentialChangeInvalidatesCacheAndHandlesMalformedAnd24hWindows() async throws {
        final class CredBox: @unchecked Sendable {
            let lock = NSLock()
            var current: CodexQuotaProvider.Credentials? = CodexQuotaProvider.Credentials(
                accessToken: "at-1",
                refreshToken: "rt-1",
                accountID: "acct-1"
            )
        }
        let credBox = CredBox()
        let usageJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1794897454 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "Codex-Daily",
              "rate_limit": {
                "primary_window": { "used_percent": 50, "limit_window_seconds": 86400, "reset_at": 1794897454 },
                "secondary_window": { "used_percent": 30, "limit_window_seconds": 604800, "reset_at": 1794920759 }
              }
            },
            {
              "limit_name": "Codex-Daily",
              "rate_limit": {
                "secondary_window": { "used_percent": 40, "limit_window_seconds": 604800, "reset_at": 1794920759 }
              }
            },
            {
              "limit_name": "Broken",
              "rate_limit": {
                "primary_window": { "limit_window_seconds": 18000 }
              }
            }
          ]
        }
        """
        let transport = MockHTTPTransport(handlers: [
            { _ in HTTPResponseData(data: Data(), statusCode: 401) },
            { _ in HTTPResponseData(data: Data(#"{"access_token":"at-refreshed","refresh_token":"rt-2"}"#.utf8), statusCode: 200) },
            { req in
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer at-refreshed")
                return HTTPResponseData(data: Data(usageJSON.utf8), statusCode: 200)
            },
            { req in
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer at-new-account")
                return HTTPResponseData(data: Data(usageJSON.utf8), statusCode: 200)
            },
        ])
        let provider = CodexQuotaProvider(
            transport: transport,
            subprocess: MockSubprocessRunner(resolvedPaths: ["codex": "/usr/local/bin/codex"]),
            credentialReader: { credBox.lock.withLock { credBox.current } }
        )

        let first = try await provider.fetchUsage()
        XCTAssertEqual(first.windows.count, 4)
        XCTAssertEqual(first.windows[1].cadence, .other) // 86400s is 24h, not 7d
        XCTAssertEqual(Set(first.windows.map(\.id)).count, first.windows.count)

        // Simulate external account switch in ~/.codex/auth.json
        credBox.lock.withLock {
            credBox.current = CodexQuotaProvider.Credentials(
                accessToken: "at-new-account",
                refreshToken: "rt-new",
                accountID: "acct-2"
            )
        }
        _ = try await provider.fetchUsage()
    }

    func testAntigravityExtractsJSONWithNoisyBracesAndCodexAnnouncementValidatesURLAndErrorCache() async throws {
        let noisyStdout = """
        [warn] config {legacy} ignored
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"g1","window":"5h","remaining_fraction":0.5,"reset_time":"2026-11-17T06:00:00Z"}]}]}}}
        [debug] done {ok}
        """
        let snapshot = try AntigravityQuotaProvider.parseUsageOutput(
            SubprocessOutput(exitCode: 0, stdout: Data(noisyStdout.utf8), stderr: Data())
        )
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 50.0, accuracy: 0.001)

        // Malicious URL scheme rejected
        let badURLJSON = #"{"latest_alert":{"id":"1","kind":"watch","state":"active","url":"javascript:alert(1)"}}"#
        let parsedBad = CodexResetAnnouncementService.parseForecast(Data(badURLJSON.utf8))
        XCTAssertNil(parsedBad?.sourceURL)

        // Error clears cached announcement inside 300s throttle window
        let goodJSON = #"{"latest_alert":{"id":"1","kind":"watch","state":"active","url":"https://codex-reset.com/watch"}}"#
        let transport = MockHTTPTransport(handlers: [
            { _ in HTTPResponseData(data: Data(goodJSON.utf8), statusCode: 200) },
            { _ in HTTPResponseData(data: Data(), statusCode: 500) },
        ])
        let service = CodexResetAnnouncementService(transport: transport)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = await service.fetchAnnouncement(now: t0)
        XCTAssertNotNil(initial)
        let failed = await service.fetchAnnouncement(now: t0.addingTimeInterval(301))
        XCTAssertNil(failed)
        let throttledAfterFailure = await service.fetchAnnouncement(now: t0.addingTimeInterval(310))
        XCTAssertNil(throttledAfterFailure)
    }
}
