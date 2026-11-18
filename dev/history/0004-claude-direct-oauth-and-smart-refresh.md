# 0004: Claude In-App OAuth and Per-Provider Smart Refresh

## Context

Claude usage kept dropping out. The `statusLine` cache only updates while Claude Code is running, so after 15 idle minutes the app fell back to reading the CLI's `Claude Code-credentials` Keychain item, and that read failed with `errSecAuthFailed` (-25293) every time. The app is ad-hoc signed (`codesign --sign -`), so the signature changes on every build and an "Always Allow" grant never sticks. Polling also used one fixed timer for every provider, with a 429 cooldown for Claude only and no handling of wake, App Nap, or back-to-back requests. `Usage4Claude` was used as the reference for both.

## Decisions & Rationale

### 1. Claude Signs In Inside the App (Supersedes `0001` §1 for Claude)
- **Decision**: Claude no longer reads the CLI's Keychain item, `~/.claude/.credentials.json`, the `statusLine` cache, or `claude auth status`. Settings → Providers → Claude runs a PKCE OAuth sign-in in the system browser with a localhost callback (ports 1456, then 1458), stores the app's own refresh token in an app-owned Keychain item (`com.agentquotabar.app.claude-oauth`), refreshes it itself, and calls `api.anthropic.com/api/oauth/usage`.
- **Why**: The app depends on nothing the CLI controls, so it works when Claude Code is idle and when the CLI's Keychain ACL refuses the app. Because the refresh token is the app's own, rotating it cannot log the CLI out, which is what `0003` §1 required before token refresh could return.
- **Caveats**:
  - It reuses Claude Code's public OAuth client ID with the read-only `user:profile` scope, as `Usage4Claude` does. A change to Anthropic's client policy would break sign-in.
  - Refresh tokens rotate. Concurrent fetches share one refresh (`ClaudeQuotaProvider.refreshedCredentials`), and a rotated token is cached in memory before the Keychain write, so a failed write only loses it on restart. Never exchange the same refresh token twice.
  - `400 invalid_grant` / `401` from the token endpoint means the login is dead: credentials are deleted and the status becomes `loginRequired`. Do not treat it as a retryable HTTP error.
  - The app-owned Keychain item is still tied to the code signature, so ad-hoc rebuilds may ask for Keychain access again. A stable signing identity removes this.
  - Codex and Antigravity still use their CLIs read-only (`0003` §1 still applies to them).

### 2. Per-Provider Smart Refresh Replaces the Fixed Interval (Resolves `0001` §4 Deferral)
- **Decision**: The refresh interval setting is removed. Each provider has its own `SmartRefreshState`: every 1 minute while its usage changes, stepping down to 3, 5, then 10 minutes after 3, 6, and 12 unchanged fetches. Opening the popover or pressing refresh returns every provider to 1 minute. `QuotaStore` keeps one scheduled task per provider and reschedules it after every request.
- **Why**: Providers cost very different amounts to poll (an HTTP call vs. a CLI run of up to 35 s). A shared level, as in `Usage4Claude`, would make an idle Antigravity run its CLI every minute just because Claude is busy.

### 3. One Backoff Policy in the Store for All Providers
- **Decision**: `FetchBackoffPolicy` backs off automatic fetches after 429, 5xx, CLI failures, and network errors: 1, 2, 4, 8, 16, then 30 minutes (network errors cap at 5), with up to 20% jitter that only delays and `Retry-After` honored up to 1 hour (`0` ignored). Login and payload errors do not back off. The refresh button and opening the popover bypass it, with a 10-second minimum gap.
- **Why**: Retrying a rate limit on a fixed schedule keeps renewing it. The old Claude-only 15→60-minute cooldown also blocked the user's own refresh.
- **Note**: Requests outside the schedule (popover, refresh button, wake) reschedule the provider's timer instead of letting the scheduled fetch follow seconds later; such bursts are what triggered 429s in `Usage4Claude`.

### 4. Wake, App Nap, and Logs
- **Decision**: Refresh 3 seconds after `NSWorkspace.didWakeNotification`, hold a `userInitiatedAllowingIdleSystemSleep` activity while polling, and log provider IDs, error cases, and backoff delays as `.public` (never tokens, emails, or response bodies).
- **Why**: Earlier logs showed only `<private>`, so the failures could not be diagnosed.
