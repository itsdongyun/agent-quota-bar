# 0001: Initial Architecture, Local CLI Auth, and Scope Decisions

## Context

`agent-quota-bar` monitors subscription usage quotas across three AI coding agents (**Claude**, **Codex**, **Antigravity**) from the macOS menu bar, inspired by `Usage4Claude` and `CodexBar`.

## Decisions & Rationale

### 1. Local CLI Reuse Without Separate In-App Authentication
- **Decision**: Do not build an in-app browser/WebView/OAuth login UI or multi-account switcher. Reuse each CLI's existing local login state:
  - **Claude**: Read `Claude Code-credentials` from macOS Keychain (or `~/.claude/.credentials.json` if present) and call `api.anthropic.com/api/oauth/usage`. Verify login metadata via `claude auth status --json`. Do **not** run `claude -p "/usage"` because unsupported slash commands in print mode can be sent as billable/token-consuming prompts.
  - **Codex**: Read `~/.codex/auth.json` directly and call `chatgpt.com/backend-api/wham/usage`.
  - **Antigravity**: Run `agy -p "/usage" --output-format json --print-timeout 30s` (verified 0 LLM tokens consumed on `agy 1.5.9`).
- **Why**: Avoids duplicating login flows and avoids probing undocumented local language-server ports or scraping fragile interactive TUI output.
- **Caveat for future changes**: Reading `"Claude Code-credentials"` from Keychain via `SecItemCopyMatching` triggers a one-time macOS Keychain access prompt when run from a separate app bundle; if denied, surface a clear status message rather than falling back to invasive workarounds. Also never overwrite Claude/Codex CLI's own credential stores—keep refreshed tokens in memory/app-scoped cache only.

### 2. Unified 7-Day Normalized Pace Chart in Popover
- **Decision**: Render a single 7-day chart (`X = 0%..100%` elapsed ratio of each 7-day reset window, `Y = 0%..100%` usage) plotting all active providers with distinct token colors, a `0% -> 100%` diagonal pace baseline, and direct point labels, followed by user-filtered limit rows (`5h`, `7d`, model-specific).
- **Why**: Each provider's 7-day quota resets on a different weekday/timestamp, so normalizing X to elapsed window progress allows side-by-side comparison of consumption pace on one compact popover graph.

### 3. Codex-Only Global Reset Announcement
- **Decision**: Support `codex-reset.com/api/forecast` (`latest_alert`) only for Codex, failing silently (`nil`) on errors.
- **Why**: Regular scheduled `reset_at` countdowns already come from every provider's own usage response. The "reset announcement" badge in `Usage4Claude` tracks OpenAI Codex's ad-hoc global resets via a third-party community tracker; no equivalent exists for Claude or Antigravity.

### 4. Deferred / Excluded Features
- **Deferred**: Adaptive/smart polling & exponential backoff tuning (abstracted behind `RefreshInterval` / `QuotaStore` so a policy can be plugged in later).
- **Excluded**: Push/local notifications, Sparkle auto-update, dedicated diagnostic log viewer UI (replaced by `OSLog` + concise inline connection status).
