# agent-quota-bar agent instructions

An open-source macOS menu bar app written in Swift for monitoring AI agent usage and quotas at a glance.

Do not modify instruction files unless the user explicitly asks. They hold lasting guidance for future development, not work logs.

## Instruction files

- Keep agent rules in `AGENTS.md`; each `CLAUDE.md` contains only `@AGENTS.md`.
- Put setup and deployment notes in `AGENTS.md`, not in new README files.

## UI

- Style with the app's design tokens only. No hardcoded colors, spacing, type sizes, radius, or shadows.
- When a needed value has no token, add the token in the same change. When a design value changes, change the token, not each screen.
- Icons come from SF Symbols only.
- UI strings support Korean (`ko`). Every user-facing string is written in each supported language.

## Development records

- `dev/` holds development documents. Create it when the first document is needed.
- `dev/history/` records decisions, not plain implementation: the direction chosen and why, and anything a later implementation could misread or redo differently.
- Ask the user for approval before writing to `dev/history/`. Propose it when a decision like that comes up.
