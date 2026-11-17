# agent-quota-bar Implementation Plan

## Scope Summary

- **Target**: macOS menu bar app (`Swift` / `SwiftUI` + `AppKit`, macOS 14+) with zero external dependencies.
- **Providers (3)**: Claude (`claude`), Codex (`codex`), Antigravity (`agy`).
- **Authentication**: Reuse existing local CLI credentials/sessions without separate in-app login flows (single account per provider).
- **Quotas**: Subscription limits only — `5h`, `7d`, and model-specific limits, filterable by user selection in Settings.
- **UI (3 surfaces)**:
  1. **Menu Bar**: Icon only (SF Symbols), toggles popover.
  2. **Popover**: Unified 7-day window progress (X: 0%–100%) × usage (Y: 0%–100%) pace chart combining grid/diagonal pace guide with provider-colored points & labels, plus filtered limit progress rows + reset countdowns, and a conditional Codex global reset announcement badge (`codex-reset.com`).
  3. **Settings**: Local CLI connection status, per-provider limit visibility toggles (`5h` / `7d` / model-specific), refresh interval + `Launch at Login` (`SMAppService`).
- **Excluded**: Multi-account switching, macOS notifications, Sparkle auto-update, dedicated diagnostic log viewer UI (use `OSLog` + concise inline error status).
- **Project Rules**: Design tokens only (`DesignTokens.swift`), SF Symbols only, `en` and `ko` localization (`Localizable.strings`).

---

## Verified Local CLI Integration Contracts

1. **Claude (`claude`)**
   - Status check: `claude auth status --json` (`loggedIn`, `email`, `subscriptionType`, `planTier`).
   - Credentials: `~/.claude/.credentials.json` first, then macOS Keychain (`service: "Claude Code-credentials"`).
   - Usage API: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/<version> (external, cli)`.
   - Token refresh (if expired, kept in app memory/cache without mutating Claude CLI's own Keychain item): `POST https://platform.claude.com/v1/oauth/token` (`client_id: 9d1c250a-e61b-44d9-88ed-5944d1962f5e`).
   - Parses `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, and `limits` (`weekly_scoped`).

2. **Codex (`codex`)**
   - Status check: existence of `~/.codex/auth.json` (and `tokens.access_token`).
   - Usage API: `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <token>` and `ChatGPT-Account-Id` header.
   - Token refresh (in memory if expired): `POST https://auth.openai.com/oauth/token` (`client_id: app_EMoamEEZ73f0CkXaXp7hrann`).
   - Parses `plan_type`, `rate_limit.primary_window` (5h), `rate_limit.secondary_window` (7d), and `additional_rate_limits`.
   - Global reset announcement: `GET https://codex-reset.com/api/forecast` → `latest_alert` (silent nil on failure).

3. **Antigravity (`agy`)**
   - Command: `agy -p "/usage" --output-format json --print-timeout 30s` (uses 0 LLM tokens, ~8s runtime).
   - Runs in an isolated temp directory with stubbed `open`/`xdg-open` so no browser window opens on failure; coalesces in-flight calls so concurrent refreshes never spawn duplicate `agy` processes.
   - Parses `command.data.groups[]` → `buckets[]` (`id`, `name`, `window` `"5h"` / `"weekly"`, `remaining_fraction`, `reset_time`).

---

## Module Architecture (SwiftPM)

```text
Package.swift
├── Sources/AgentQuotaCore/          # Pure Swift models, providers, parsing, localization keys, store
│   ├── Models/
│   │   ├── ProviderID.swift
│   │   ├── QuotaModels.swift        # QuotaWindow, QuotaWindowKind, ProviderQuotaSnapshot, CodexResetAnnouncement
│   │   └── QuotaSettings.swift      # User-selected window filters, refresh interval
│   ├── Providers/
│   │   ├── QuotaProvider.swift
│   │   ├── ClaudeQuotaProvider.swift
│   │   ├── CodexQuotaProvider.swift
│   │   ├── CodexResetAnnouncementService.swift
│   │   └── AntigravityQuotaProvider.swift
│   ├── Support/
│   │   ├── SubprocessRunner.swift
│   │   ├── HTTPClient.swift
│   │   └── AppLogger.swift
│   └── Store/
│       └── QuotaStore.swift         # Coordinates refreshes, coalescing, and filtered snapshot projection
├── Sources/AgentQuotaBar/           # macOS SwiftUI + AppKit UI
│   ├── DesignSystem/
│   │   └── DesignTokens.swift       # All colors, spacing, typography, radii, shadows, chart styles
│   ├── Localization/
│   │   └── L10n.swift               # Bundle.module en/ko lookup
│   ├── Resources/
│   │   ├── en.lproj/Localizable.strings
│   │   ├── ko.lproj/Localizable.strings
│   │   └── Info.plist
│   ├── App/
│   │   ├── AgentQuotaBarApp.swift
│   │   └── LaunchAtLoginManager.swift
│   └── Views/
│       ├── MenuBarIconView.swift
│       ├── Popover/
│       │   ├── UsagePopoverView.swift
│       │   ├── SevenDayPaceChartView.swift
│       │   └── QuotaWindowRowView.swift
│       └── Settings/
│           └── SettingsView.swift
└── Tests/AgentQuotaCoreTests/       # Unit tests for JSON decoding, window filtering, pace math, announcements
```

---

## Implementation Phases

- **Phase 1**: Package setup (`Package.swift`), `AgentQuotaCore` models, `DesignTokens`, `en`/`ko` localization, `AgentQuotaBar` menu bar shell.
- **Phase 2**: `ClaudeQuotaProvider`, `CodexQuotaProvider`, `CodexResetAnnouncementService`, `AntigravityQuotaProvider`, plus JSON fixture unit tests.
- **Phase 3**: `QuotaStore` + `SevenDayPaceChartView` (unified 7d × usage% chart) + `UsagePopoverView` + `QuotaWindowRowView`.
- **Phase 4**: `SettingsView` (connection status, per-provider limit toggles, refresh interval, `SMAppService` launch at login), app bundle script, build & test verification.
