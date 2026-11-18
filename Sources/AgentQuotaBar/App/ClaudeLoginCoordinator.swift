import AppKit
import AgentQuotaCore
import Observation

/// Runs the app's own "Sign in with Claude" flow: system browser → localhost callback → code exchange →
/// Keychain. The login belongs to this app only, so the Claude Code CLI's tokens are never read or rotated.
@MainActor
@Observable
final class ClaudeLoginCoordinator {
    enum Failure: Equatable {
        case portUnavailable
        case timedOut
        case denied
        case failed
    }

    enum Phase: Equatable {
        case idle
        case waitingForBrowser
        case exchanging
        case failed(Failure)
    }

    private(set) var phase: Phase = .idle
    private(set) var isSignedIn = false
    private(set) var accountEmail: String?

    private static let loginTimeout: Duration = .seconds(5 * 60)

    private let store: QuotaStore
    private let credentialStore: ClaudeCredentialStoring
    private let client: ClaudeOAuthClient
    private var server: OAuthCallbackServer?
    private var pkce: PKCECodes?
    private var redirectURI: String?
    private var authorizeURL: URL?
    private var timeoutTask: Task<Void, Never>?

    init(
        store: QuotaStore,
        credentialStore: ClaudeCredentialStoring = KeychainClaudeCredentialStore.shared,
        client: ClaudeOAuthClient = ClaudeOAuthClient()
    ) {
        self.store = store
        self.credentialStore = credentialStore
        self.client = client
        reloadAccount()
    }

    var isInProgress: Bool {
        phase == .waitingForBrowser || phase == .exchanging
    }

    func reloadAccount() {
        let credentials = (try? credentialStore.load()) ?? nil
        isSignedIn = credentials != nil
        accountEmail = credentials?.email
    }

    func signIn() {
        cancel()
        let pkce = PKCECodes()
        let server = OAuthCallbackServer(pages: OAuthCallbackServer.Pages(
            successHTML: Self.callbackPage(L10n.string("oauth.callback.success")),
            failureHTML: Self.callbackPage(L10n.string("oauth.callback.failure"))
        ))
        self.pkce = pkce
        self.server = server
        phase = .waitingForBrowser

        Task { [weak self] in
            let port = await server.start(ports: ClaudeOAuthClient.Config.callbackPorts) { [weak self] query in
                Task { @MainActor in self?.handleCallback(query) }
            }
            guard let self, self.server === server else { return } // cancelled meanwhile
            guard let port else {
                self.fail(.portUnavailable)
                return
            }
            let redirectURI = ClaudeOAuthClient.Config.redirectURI(port: port)
            let url = ClaudeOAuthClient.authorizeURL(pkce: pkce, redirectURI: redirectURI)
            self.redirectURI = redirectURI
            self.authorizeURL = url
            NSWorkspace.shared.open(url)
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.loginTimeout)
                guard !Task.isCancelled, let self, self.phase == .waitingForBrowser else { return }
                self.fail(.timedOut)
            }
        }
    }

    func reopenBrowser() {
        guard phase == .waitingForBrowser, let authorizeURL else { return }
        NSWorkspace.shared.open(authorizeURL)
    }

    func cancel() {
        stopListening()
        pkce = nil
        redirectURI = nil
        authorizeURL = nil
        phase = .idle
    }

    func signOut() {
        cancel()
        credentialStore.delete()
        reloadAccount()
        store.claudeDidSignOut()
        AppLogger.app.info("Claude signed out")
    }

    // MARK: - Private

    private func handleCallback(_ query: [String: String]) {
        guard phase == .waitingForBrowser, let pkce, let redirectURI else { return }
        stopListening()
        guard query["state"] == pkce.state else {
            AppLogger.app.error("Claude sign-in callback state mismatch; ignoring it")
            fail(.failed)
            return
        }
        if query["error"] != nil {
            fail(.denied)
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            fail(.failed)
            return
        }

        phase = .exchanging
        Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await self.client.exchangeCode(
                    code: code,
                    state: pkce.state,
                    codeVerifier: pkce.codeVerifier,
                    redirectURI: redirectURI
                )
                guard let refreshToken = tokens.refreshToken else {
                    AppLogger.app.error("Claude sign-in response carried no refresh token")
                    self.fail(.failed)
                    return
                }
                let email = (try? await self.client.fetchEmail(accessToken: tokens.accessToken)) ?? nil
                try self.credentialStore.save(ClaudeCredentials(
                    refreshToken: refreshToken,
                    accessToken: tokens.accessToken,
                    expiresAt: tokens.expiresAt,
                    email: email
                ))
                self.pkce = nil
                self.phase = .idle
                self.reloadAccount()
                self.store.claudeDidSignIn()
                AppLogger.app.info("Claude sign-in succeeded")
            } catch {
                AppLogger.app.error("Claude sign-in failed: \(String(describing: error), privacy: .public)")
                self.fail(.failed)
            }
        }
    }

    private func fail(_ failure: Failure) {
        stopListening()
        phase = .failed(failure)
    }

    private func stopListening() {
        timeoutTask?.cancel()
        timeoutTask = nil
        server?.stop()
        server = nil
    }

    private static func callbackPage(_ message: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Agent Quota Bar</title></head>
        <body><p>\(message)</p></body></html>
        """
    }
}
