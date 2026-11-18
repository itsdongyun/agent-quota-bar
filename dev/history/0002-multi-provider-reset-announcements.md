# 0002: Multi-Provider Reset Announcements (Codex, Claude, Antigravity)

## Context

Initially (`0001`), only Codex surfaced an ad-hoc global reset badge via `codex-reset.com/api/forecast` (`kind == "watch"`). The goal was expanded to show reset badges for **Claude** and **Antigravity** as well when public third-party trackers announce global resets or redeemable reset cards.

## Decisions & Rationale

### 1. Unified `ResetAnnouncement` & `ResetAnnouncementService`
- **Decision**: Replace `CodexResetAnnouncement` / `CodexResetAnnouncementService` with `ResetAnnouncement` (`provider`, `kind`: `.watch | .bankedReset | .recentReset`) and a single `ResetAnnouncementService` managing per-provider 300-second throttling and in-flight coalescing.
- **Why**: Unlike Codex (`codex-reset.com`), neither Claude nor Antigravity has a reliable pre-announcement "watch" feed. Instead, they publish post-announcement global resets or time-limited banked reset grants.

### 2. Provider Sources & Active Windows
- **Codex (`https://codex-reset.com/api/forecast`)**: Keeps `.watch` alerts only (`state` in `watch` / `active`, up to `windowEnd + 1h`). Confirmed historical resets remain inactive.
- **Claude (`https://claude-resets.com/data/summary.json`)**:
  - Chosen over `whenreset.dev` (which imposes strict 429 rate limits on direct desktop clients) and `limitreset.dev` / `usagereset.com` (seed/synthetic signals).
  - Surfaces `.bankedReset` grants (`bankedResets[]` / `lastResetType == "banked"`) while unexpired (`expiresAt == nil || now <= expiresAt`) and announced within **7 days** (`ResetAnnouncement.bankedResetMaxAge`), so month-long grant windows do not permanently clutter the popover header when the app cannot tell if the user already redeemed the card.
  - Surfaces immediate global `.recentReset` notices within **24 hours** (`ResetAnnouncement.recentResetMaxAge`).
- **Antigravity (`https://antigravityreset.com/api/state`)**:
  - Surfaces verified `.recentReset` announcements from `@_mohansolo` within **24 hours**.
  - **Caveat**: `antigravityreset.com/api/state` is an undocumented frontend endpoint whose `monitor.state` was observed as `"stale"` (`lastCheckAt` lagging behind manual updates). All failures continue to fail silently (`nil`) so third-party tracker outages or schema changes never degrade local quota monitoring.
