import Foundation

/// Shared date and JWT parsing utilities for provider payloads.
public enum DateParsing {
    private final class ISO8601Cache: @unchecked Sendable {
        let lock = NSLock()
        let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let standard: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }

    private static let isoCache = ISO8601Cache()

    public static func parseISO8601(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return isoCache.lock.withLock {
            isoCache.fractional.date(from: raw) ?? isoCache.standard.date(from: raw)
        }
    }

    public static func parseUnixTimestamp(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        // Heuristic: values > 1e12 are milliseconds (e.g. Claude OAuth expiresAt).
        let seconds = value > 1_000_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    /// Extracts `exp` claim from an unverified JWT payload for expiry checks.
    public static func jwtExpiry(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}
