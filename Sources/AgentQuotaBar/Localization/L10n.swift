import Foundation
import SwiftUI
import AgentQuotaCore

/// Localization helper backed by `Bundle.module` supporting English (`en`) and Korean (`ko`).
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: Locale.current, arguments: args)
    }

    static func markdownText(_ key: String) -> Text {
        let raw = string(key)
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(raw)
    }

    static func statusText(_ status: ProviderConnectionStatus, now: Date = Date()) -> String {
        switch status {
        case .unknown:
            return string("status.unknown")
        case .connected:
            return string("status.connected")
        case .notInstalled:
            return string("status.not_installed")
        case .loginRequired:
            return string("status.login_required")
        case .keychainDenied:
            return string("status.keychain_denied")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return format("status.rate_limited_until", countdownText(until: retryAfter, now: now))
            }
            return string("status.rate_limited")
        case let .error(detail):
            return format("status.error_detail", errorDetailText(detail))
        }
    }

    static func errorDetailText(_ detail: ProviderErrorDetail) -> String {
        switch detail {
        case let .httpStatus(code):
            return format("error.http_status", code)
        case let .invalidPayload(provider):
            return format("error.invalid_payload", provider.displayName)
        case let .missingJSON(provider):
            return format("error.missing_json", provider.displayName)
        case let .cliExited(provider, code):
            return format("error.cli_exited", provider.displayName, code)
        case let .cliStatus(provider, status):
            return format("error.cli_status", provider.displayName, status)
        case let .message(message):
            return message
        }
    }

    static func resetInText(until date: Date?, now: Date = Date()) -> String {
        guard let date else {
            return format("reset.in", string("reset.unknown"))
        }
        if date.timeIntervalSince(now) <= 0 {
            return string("reset.in_pending")
        }
        return format("reset.in", countdownText(until: date, now: now))
    }

    static func countdownText(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return string("reset.unknown") }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 {
            return string("reset.pending")
        }
        let seconds = Int(remaining)
        if seconds < 60 {
            return string("reset.soon")
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return format("reset.days_hours", days, hours)
        }
        if hours > 0 {
            return format("reset.hours_minutes", hours, minutes)
        }
        return format("reset.minutes", minutes)
    }

    static func mockPresetTitle(_ preset: MockScenarioPreset) -> String {
        switch preset {
        case .design: return string("mock.preset.design")
        case .relaxed: return string("mock.preset.relaxed")
        case .overPace: return string("mock.preset.over_pace")
        case .nearLimit: return string("mock.preset.near_limit")
        case .justReset: return string("mock.preset.just_reset")
        case .errors: return string("mock.preset.errors")
        case .loading: return string("mock.preset.loading")
        case .empty: return string("mock.preset.empty")
        }
    }

    static func mockStatusTitle(_ status: MockProviderStatus) -> String {
        switch status {
        case .connected: return string("status.connected")
        case .loading: return string("mock.status.loading")
        case .notInstalled: return string("status.not_installed")
        case .loginRequired: return string("status.login_required")
        case .keychainDenied: return string("status.keychain_denied")
        case .rateLimited: return string("status.rate_limited")
        case .error: return string("mock.status.error")
        }
    }

    static func mockCadenceTitle(_ cadence: MockShortCadence) -> String {
        switch cadence {
        case .fiveHour: return string("mock.cadence.five_hour")
        case .daily: return string("mock.cadence.daily")
        }
    }

    static func slotTitle(_ slot: UsageSlot) -> String {
        switch slot {
        case .short: return string("popover.slot_short")
        case .weekly: return string("popover.slot_weekly")
        }
    }

    /// Reset moment as a clock time when it is within a day, otherwise as a short date with weekday.
    static func resetClockText(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return string("popover.no_value") }
        if date.timeIntervalSince(now) <= 0 {
            return string("reset.pending")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let withinDay = date.timeIntervalSince(now) < 24 * 3600
        formatter.dateFormat = string(withinDay ? "reset.time_format" : "reset.date_format")
        return formatter.string(from: date)
    }

    static func localizedWindowLabel(_ window: QuotaWindow) -> String {
        switch window.category {
        case .fiveHour:
            return string("window.five_hour")
        case .sevenDay:
            return string("window.seven_day")
        case .modelSpecific:
            if let model = window.modelName {
                switch window.cadence {
                case .fiveHour:
                    return "\(model) (\(string("cadence.short.5h")))"
                case .sevenDay:
                    return "\(model) (\(string("cadence.short.7d")))"
                case .other:
                    let hours = max(1, Int((window.windowDurationSeconds / 3600).rounded()))
                    let suffix = hours >= 24 && hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
                    return "\(model) (\(suffix))"
                }
            }
            return window.label
        }
    }
}
