import Foundation
import SwiftUI
import AgentQuotaCore

/// Localization helper backed by `Bundle.appResources` supporting English (`en`) and Korean (`ko`).
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .appResources, value: key, comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: Locale.current, arguments: args)
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
        case .sessionExpired:
            return string("status.session_expired")
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

    static func slotTitle(_ slot: UsageSlot) -> String {
        switch slot {
        case .short: return string("popover.slot_short")
        case .weekly: return string("popover.slot_weekly")
        }
    }

    /// The reset's local calendar day and clock time, or a status when the time is unavailable.
    static func resetClock(until date: Date?, now: Date) -> (day: String?, time: String) {
        guard let date else { return (nil, string("popover.no_value")) }
        guard date > now else { return (nil, string("reset.pending")) }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.appResources.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = string("reset.time_format")
        let time = formatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return (string("reset.today"), time)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return (string("reset.tomorrow"), time)
        }

        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        formatter.dateFormat = string(sameYear ? "reset.date_format" : "reset.date_format_with_year")
        return (formatter.string(from: date), time)
    }

    static func resetClockText(until date: Date?, now: Date = Date()) -> String {
        let reset = resetClock(until: date, now: now)
        return reset.day.map { "\($0) \(reset.time)" } ?? reset.time
    }

    static func localizedWindowLabel(_ window: QuotaWindow) -> String {
        switch window.category {
        case .fiveHour:
            return string("window.five_hour")
        case .sevenDay:
            return string("window.seven_day")
        case .modelSpecific:
            let cadence = cadenceShortText(window)
            if let model = window.modelName {
                return format("window.model_cadence", model, cadence)
            }
            return format("window.quota_cadence", cadence)
        }
    }

    /// Compact window length such as "5h", "7d" or "24h", in the current language.
    static func cadenceShortText(_ window: QuotaWindow) -> String {
        switch window.cadence {
        case .fiveHour:
            return string("cadence.short.5h")
        case .sevenDay:
            return string("cadence.short.7d")
        case .other:
            let hours = max(1, Int((window.windowDurationSeconds / 3600).rounded()))
            if hours >= 24 && hours % 24 == 0 {
                return format("cadence.short.days", hours / 24)
            }
            return format("cadence.short.hours", hours)
        }
    }
}
