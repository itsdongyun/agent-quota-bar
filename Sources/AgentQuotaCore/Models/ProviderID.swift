import Foundation

/// Supported AI agent providers monitored by agent-quota-bar.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}
