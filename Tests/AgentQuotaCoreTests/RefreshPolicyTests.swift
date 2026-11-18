import XCTest
@testable import AgentQuotaCore

final class RefreshPolicyTests: XCTestCase {
    private func snapshot(_ percent: Double) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(provider: .codex, windows: [
            QuotaWindow(id: "w", provider: .codex, category: .fiveHour, cadence: .fiveHour,
                        label: "5h", usedPercent: percent, resetsAt: nil),
        ])
    }

    // MARK: - Smart refresh

    func testSmartRefreshStepsDownWhileUsageStaysTheSame() {
        var state = SmartRefreshState()
        state.record(snapshot(10)) // first observation: nothing to compare
        XCTAssertEqual(state.unchangedCount, 0)
        XCTAssertEqual(state.interval, 60)

        for _ in 0..<3 { state.record(snapshot(10)) }
        XCTAssertEqual(state.mode, .idleShort)
        XCTAssertEqual(state.interval, 180)

        for _ in 0..<6 { state.record(snapshot(10)) }
        XCTAssertEqual(state.mode, .idleMedium)

        for _ in 0..<12 { state.record(snapshot(10)) }
        XCTAssertEqual(state.mode, .idleLong)
        XCTAssertEqual(state.interval, 600)

        state.record(snapshot(10))
        XCTAssertEqual(state.mode, .idleLong)
    }

    func testSmartRefreshReturnsToActiveOnChangeOrActivate() {
        var state = SmartRefreshState()
        for _ in 0..<5 { state.record(snapshot(10)) }
        XCTAssertEqual(state.mode, .idleShort)

        state.record(snapshot(10.005)) // below the change threshold
        XCTAssertEqual(state.mode, .idleShort)

        state.record(snapshot(11))
        XCTAssertEqual(state.mode, .active)
        XCTAssertEqual(state.unchangedCount, 0)

        for _ in 0..<3 { state.record(snapshot(11)) }
        XCTAssertEqual(state.mode, .idleShort)
        state.activate()
        XCTAssertEqual(state.mode, .active)
    }

    func testSmartRefreshSlowsDownForEmptySnapshotsAndWakesOnNewWindow() {
        var state = SmartRefreshState()
        let empty = ProviderQuotaSnapshot(provider: .claude, windows: [])
        for _ in 0..<4 { state.record(empty) }
        XCTAssertEqual(state.mode, .idleShort)

        state.record(snapshot(0)) // a window appears, even at 0% usage
        XCTAssertEqual(state.mode, .active)
    }

    // MARK: - Backoff

    func testBackoffDoublesFromOneMinuteAndCaps() {
        let delays = (1...7).map {
            FetchBackoffPolicy.delay(consecutiveFailures: $0, failure: .serverError, jitterFraction: 0)
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 960, 1800, 1800])
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 9, failure: .network, jitterFraction: 0), 300)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1_000, failure: .serverError, jitterFraction: 0), 1800)
    }

    func testBackoffHonorsRetryAfterWithinLimitAndJitterOnlyDelays() {
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1, failure: .rateLimited(retryAfter: 600), jitterFraction: 0), 600)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 3, failure: .rateLimited(retryAfter: 30), jitterFraction: 0), 240)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1, failure: .rateLimited(retryAfter: 86_400), jitterFraction: 0), 3600)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1, failure: .serverError, jitterFraction: 0.2), 72, accuracy: 0.001)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1, failure: .serverError, jitterFraction: 5), 72, accuracy: 0.001)
        XCTAssertEqual(FetchBackoffPolicy.delay(consecutiveFailures: 1, failure: .serverError, jitterFraction: -1), 60)
    }

    func testBackoffStateGatesFetchesUntilRetryTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = FetchBackoffPolicy.recordFailure(.initial, failure: .serverError, now: now, jitterFraction: 0)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(FetchBackoffPolicy.shouldFetch(state, now: now.addingTimeInterval(59)))
        XCTAssertTrue(FetchBackoffPolicy.shouldFetch(state, now: now.addingTimeInterval(60)))
        XCTAssertTrue(FetchBackoffPolicy.shouldFetch(.initial, now: now))
    }

    func testBackoffClassifiesOnlyRetryWorseningErrors() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            FetchBackoffPolicy.failure(for: QuotaProviderError.rateLimited(retryAfter: now.addingTimeInterval(90)), now: now),
            .rateLimited(retryAfter: 90)
        )
        XCTAssertEqual(
            FetchBackoffPolicy.failure(for: QuotaProviderError.rateLimited(retryAfter: now.addingTimeInterval(-5)), now: now),
            .rateLimited(retryAfter: nil)
        )
        XCTAssertEqual(FetchBackoffPolicy.failure(for: QuotaProviderError.httpError(502), now: now), .serverError)
        XCTAssertEqual(FetchBackoffPolicy.failure(for: QuotaProviderError.executionFailed(.message("x")), now: now), .serverError)
        XCTAssertEqual(FetchBackoffPolicy.failure(for: URLError(.notConnectedToInternet), now: now), .network)
        XCTAssertNil(FetchBackoffPolicy.failure(for: QuotaProviderError.httpError(404), now: now))
        XCTAssertNil(FetchBackoffPolicy.failure(for: QuotaProviderError.loginRequired, now: now))
        XCTAssertEqual(FetchBackoffPolicy.failure(for: QuotaProviderError.keychainDenied, now: now), .authFailure)
        XCTAssertEqual(FetchBackoffPolicy.failure(for: QuotaProviderError.sessionExpired, now: now), .authFailure)
        XCTAssertNil(FetchBackoffPolicy.failure(for: QuotaProviderError.invalidResponse(.invalidPayload(.codex)), now: now))
    }
}
