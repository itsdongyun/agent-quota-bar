# 0003: Passive CLI Token Handling and Packaged Resource Bundle Lookup

## Context

Code review after `0001` surfaced two issues that affect real-world usage and distribution:
1. Refreshing OAuth tokens inside `ClaudeQuotaProvider` and `CodexQuotaProvider` (even when kept in memory, per `0001`) invalidates the CLI's on-disk/Keychain refresh token when the auth server rotates refresh tokens, logging the user out of `claude` / `codex` on their next CLI run and losing the rotated token when the app restarts.
2. SwiftPM's generated `Bundle.module` accessor only searches next to the executable (`.app` root) and the build machine's absolute `.build` path, whereas `scripts/bundle-app.sh` places `agent-quota-bar_AgentQuotaBar.bundle` in `Contents/Resources`. Running the `.app` on another Mac or without `.build` triggered `fatalError`.

## Decisions & Rationale

### 1. Read-Only CLI Credentials with `.sessionExpired` Status (Supersedes `0001` Refresh Caveat)
- **Decision**: Remove OAuth refresh requests from `ClaudeQuotaProvider` and `CodexQuotaProvider`. On an expired access token or `401`, re-read the CLI's credential store once in case the CLI already renewed it; if still expired/rejected, surface `ProviderConnectionStatus.sessionExpired` / `QuotaProviderError.sessionExpired` prompting the user to run the CLI once.
- **Why**: Keeping refreshed tokens in memory broke single-use rotating refresh tokens in the CLI's own store, while writing back to the CLI's Keychain/`auth.json` would race with and mutate another tool's credentials. Treating the CLI's credential store as strictly read-only avoids breaking `claude` or `codex` logins.
- **Note for future changes**: Do not re-add `/oauth/token` refresh calls unless the app switches to its own independent login flow.

### 2. `Bundle.appResources` Wrapper for Packaged `.app` Bundles
- **Decision**: Introduce `Bundle.appResources` (`Sources/AgentQuotaBar/Localization/ResourceBundle.swift`) checking `Bundle.main.resourceURL` (`Contents/Resources`) and `Bundle.main.bundleURL` before falling back to `Bundle.module` (for `swift run` / development builds).
- **Why**: Keeps `scripts/bundle-app.sh`'s standard macOS `Contents/Resources` layout intact without relying on `Bundle.module`'s hardcoded `.build` path.
- **Note for future changes**: Always reference `Bundle.appResources` (never `Bundle.module` directly) from app UI and localization code.
