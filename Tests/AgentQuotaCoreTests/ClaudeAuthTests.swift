import XCTest
@testable import AgentQuotaCore

final class ClaudeAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let usageJSON = """
    {
      "five_hour": { "utilization": 12, "resets_at": "2026-11-18T10:00:00Z" },
      "seven_day": { "utilization": 34, "resets_at": "2026-11-22T05:00:00Z" }
    }
    """

    private func makeProvider(
        _ transport: MockHTTPTransport,
        store: InMemoryClaudeCredentialStore
    ) -> ClaudeQuotaProvider {
        let now = self.now
        return ClaudeQuotaProvider(transport: transport, credentialStore: store, nowProvider: { now })
    }

    private func isTokenRequest(_ request: URLRequest) -> Bool {
        request.url == ClaudeOAuthClient.Config.tokenURL
    }

    private func body(of request: URLRequest) -> [String: String] {
        guard let data = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return json
    }

    // MARK: - PKCE & authorize URL

    func testPKCEChallengeMatchesRFC7636Example() {
        let codes = PKCECodes(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        XCTAssertEqual(codes.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomPKCECodesAreURLSafeAndUnique() {
        let first = PKCECodes()
        let second = PKCECodes()
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertNotEqual(first.state, second.state)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(first.codeVerifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertGreaterThanOrEqual(first.codeVerifier.count, 43)
    }

    func testAuthorizeURLCarriesPKCEAndReadOnlyScope() throws {
        let codes = PKCECodes(codeVerifier: "verifier", state: "state-1")
        let url = ClaudeOAuthClient.authorizeURL(pkce: codes, redirectURI: "http://localhost:1456/callback")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], ClaudeOAuthClient.Config.clientID)
        XCTAssertEqual(query["redirect_uri"], "http://localhost:1456/callback")
        XCTAssertEqual(query["scope"], "user:profile")
        XCTAssertEqual(query["code_challenge"], codes.codeChallenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-1")
    }

    func testCallbackServerParsesOnlyTheCallbackPath() {
        let query = OAuthCallbackServer.parseQuery(
            fromRequest: "GET /callback?code=a%2Bb&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        XCTAssertEqual(query["code"], "a+b")
        XCTAssertEqual(query["state"], "xyz")
        XCTAssertTrue(OAuthCallbackServer.parseQuery(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n").isEmpty)
    }

    // MARK: - Provider

    func testNoLoginReportsLoginRequiredWithoutNetwork() async throws {
        let transport = MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
        let provider = makeProvider(transport, store: InMemoryClaudeCredentialStore())

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected loginRequired")
        } catch let error as QuotaProviderError {
            XCTAssertEqual(error, .loginRequired)
        }
        XCTAssertTrue(transport.recordedRequests.isEmpty)
        let status = await provider.checkConnectionStatus()
        XCTAssertEqual(status, .loginRequired)
    }

    func testValidAccessTokenFetchesUsageDirectly() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-1", accessToken: "at-1", expiresAt: now.addingTimeInterval(3600), email: "me@example.com"
        ))
        let usage = usageJSON
        let transport = MockHTTPTransport(handlers: [{ request in
            XCTAssertEqual(request.url, ClaudeOAuthClient.Config.usageURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), ClaudeOAuthClient.Config.betaHeader)
            return HTTPResponseData(data: Data(usage.utf8), statusCode: 200)
        }])
        let provider = makeProvider(transport, store: store)

        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 34])
        XCTAssertEqual(snapshot.accountLabel, "me@example.com")
        XCTAssertEqual(transport.recordedRequests.count, 1)
        let status = await provider.checkConnectionStatus()
        XCTAssertEqual(status, .connected)
    }

    func testExpiringTokenIsRefreshedOnceAndRotatedTokenIsSaved() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-old", accessToken: "at-old", expiresAt: now.addingTimeInterval(60), email: nil
        ))
        let usage = usageJSON
        let tokenBody = #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}"#
        let transport = MockHTTPTransport(handlers: [{ [self] request in
            if isTokenRequest(request) {
                XCTAssertEqual(body(of: request)["grant_type"], "refresh_token")
                XCTAssertEqual(body(of: request)["refresh_token"], "rt-old")
                return HTTPResponseData(data: Data(tokenBody.utf8), statusCode: 200)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
            return HTTPResponseData(data: Data(usage.utf8), statusCode: 200)
        }])
        let provider = makeProvider(transport, store: store)

        async let first = provider.fetchUsage()
        async let second = provider.fetchUsage()
        _ = try await (first, second)

        XCTAssertEqual(transport.recordedRequests.filter(isTokenRequest).count, 1)
        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.refreshToken, "rt-new")
        XCTAssertEqual(saved.accessToken, "at-new")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(3600))
    }

    func testRevokedAccessTokenIsRenewedAndRetriedOnce() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-1", accessToken: "at-revoked", expiresAt: now.addingTimeInterval(3600), email: nil
        ))
        let usage = usageJSON
        let tokenBody = #"{"access_token":"at-2","expires_in":3600}"#
        let transport = MockHTTPTransport(handlers: [
            { _ in HTTPResponseData(data: Data(), statusCode: 401) },
            { _ in HTTPResponseData(data: Data(tokenBody.utf8), statusCode: 200) },
            { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-2")
                return HTTPResponseData(data: Data(usage.utf8), statusCode: 200)
            },
        ])
        let provider = makeProvider(transport, store: store)

        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(transport.recordedRequests.count, 3)
        // The server did not rotate the refresh token, so the old one is kept.
        XCTAssertEqual(try store.load()?.refreshToken, "rt-1")
    }

    func testDeadRefreshTokenSignsOut() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-dead", accessToken: nil, expiresAt: nil, email: nil
        ))
        let transport = MockHTTPTransport(response: HTTPResponseData(
            data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400
        ))
        let provider = makeProvider(transport, store: store)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected loginRequired")
        } catch let error as QuotaProviderError {
            XCTAssertEqual(error, .loginRequired)
        }
        XCTAssertNil(try store.load())
    }

    func testTokenEndpointServerErrorKeepsLogin() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-1", accessToken: nil, expiresAt: nil, email: nil
        ))
        let transport = MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 503))
        let provider = makeProvider(transport, store: store)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected httpError")
        } catch let error as QuotaProviderError {
            XCTAssertEqual(error, .httpError(503))
        }
        XCTAssertEqual(try store.load()?.refreshToken, "rt-1")
    }

    func testUsageRateLimitReportsRetryAfter() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-1", accessToken: "at-1", expiresAt: now.addingTimeInterval(3600), email: nil
        ))
        let transport = MockHTTPTransport(response: HTTPResponseData(
            data: Data(), statusCode: 429, headers: ["Retry-After": "90"]
        ))
        let provider = makeProvider(transport, store: store)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected rateLimited")
        } catch let error as QuotaProviderError {
            guard case let .rateLimited(retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertNotNil(retryAfter)
        }
    }

    func testCodeExchangeSendsPKCEVerifier() async throws {
        let tokenBody = #"{"access_token":"at","refresh_token":"rt","expires_in":100}"#
        let transport = MockHTTPTransport(response: HTTPResponseData(data: Data(tokenBody.utf8), statusCode: 200))
        let now = self.now
        let client = ClaudeOAuthClient(transport: transport, nowProvider: { now })

        let tokens = try await client.exchangeCode(
            code: "code-1", state: "st", codeVerifier: "ver", redirectURI: "http://localhost:1456/callback"
        )
        XCTAssertEqual(tokens, ClaudeOAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: now.addingTimeInterval(100)))
        let sent = body(of: try XCTUnwrap(transport.recordedRequests.first))
        XCTAssertEqual(sent["grant_type"], "authorization_code")
        XCTAssertEqual(sent["code"], "code-1")
        XCTAssertEqual(sent["code_verifier"], "ver")
        XCTAssertEqual(sent["client_id"], ClaudeOAuthClient.Config.clientID)
    }

    func testSignOutDuringRefreshDoesNotBringTheLoginBack() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-1", accessToken: nil, expiresAt: nil, email: nil
        ))
        let tokenBody = #"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600}"#
        let transport = MockHTTPTransport(handlers: [{ _ in
            store.delete() // the user signs out while the refresh request is in flight
            return HTTPResponseData(data: Data(tokenBody.utf8), statusCode: 200)
        }])
        let provider = makeProvider(transport, store: store)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected loginRequired")
        } catch let error as QuotaProviderError {
            XCTAssertEqual(error, .loginRequired)
        }
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.recordedRequests.count, 1) // no usage call with the discarded token
    }

    func testDeadGrantOfAnOldLoginKeepsANewerSignIn() async throws {
        let store = InMemoryClaudeCredentialStore(ClaudeCredentials(
            refreshToken: "rt-old", accessToken: nil, expiresAt: nil, email: nil
        ))
        let fresh = ClaudeCredentials(
            refreshToken: "rt-new", accessToken: "at-new", expiresAt: now.addingTimeInterval(3600), email: "new@example.com"
        )
        let usage = usageJSON
        let transport = MockHTTPTransport(handlers: [
            { _ in
                try? store.save(fresh) // the user signs in again while the old refresh is in flight
                return HTTPResponseData(data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400)
            },
            { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
                return HTTPResponseData(data: Data(usage.utf8), statusCode: 200)
            },
        ])
        let provider = makeProvider(transport, store: store)

        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.accountLabel, "new@example.com")
        XCTAssertEqual(try store.load(), fresh)
    }

    func testCallbackServerAcceptsLoopbackOverIPv4AndIPv6() async throws {
        for host in ["127.0.0.1", "[::1]"] {
            let server = OAuthCallbackServer(pages: .init(successHTML: "ok", failureHTML: "fail"))
            let received = expectation(description: "callback via \(host)")
            let port = await server.start(ports: [1499, 1501]) { query in
                XCTAssertEqual(query["code"], "c1")
                received.fulfill()
            }
            let boundPort = try XCTUnwrap(port)
            let url = try XCTUnwrap(URL(string: "http://\(host):\(boundPort)/callback?code=c1&state=s1"))
            let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
            await fulfillment(of: [received], timeout: 2)
            server.stop()
        }
    }
}
