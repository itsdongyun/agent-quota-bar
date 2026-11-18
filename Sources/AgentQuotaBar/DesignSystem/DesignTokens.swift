import AppKit
import SwiftUI
import AgentQuotaCore

/// Centralized design tokens for colors, spacing, typography, radii, shadows, and chart geometry.
/// All UI views must style exclusively via these tokens.
enum DesignTokens {
    enum Colors {
        // Shared accents for provider markers and rings.
        static let claude = Color(red: 0.94, green: 0.56, blue: 0.38)
        static let codex = Color(red: 0.38, green: 0.65, blue: 0.96)
        static let antigravity = Color(red: 0.30, green: 0.78, blue: 0.47)

        static func provider(_ id: ProviderID) -> Color {
            switch id {
            case .claude: return claude
            case .codex: return codex
            case .antigravity: return antigravity
            }
        }

        // Semantic status colors
        static let statusHealthy = Color.green
        static let statusWarning = dynamic(
            light: NSColor(red: 0.80, green: 0.55, blue: 0.00, alpha: 1),
            dark: NSColor(red: 0.96, green: 0.78, blue: 0.30, alpha: 1)
        )
        static let statusNeutral = Color.secondary

        // Surface & border colors
        static let cardBackground = Color.primary.opacity(0.05)
        static let borderSubtle = Color.primary.opacity(0.10)
        static let shadowColor = Color.black.opacity(0.12)
        static let settingsTabSelectedBackground = Color.primary.opacity(0.08)
        static let settingsTabSelectedBorder = Color.primary.opacity(0.14)

        static func resetBadgeBackground(_ id: ProviderID) -> Color {
            provider(id).opacity(0.14)
        }

        static func resetBadgeBorder(_ id: ProviderID) -> Color {
            provider(id).opacity(0.35)
        }

        // Pace chart
        static let chartGridLine = Color.primary.opacity(0.08)
        static let chartPaceLine = Color.primary.opacity(0.45)
        static let legendMarker = Color.secondary

        // Menu bar rings
        static let menuBarRingTrack = Color.gray.opacity(0.45)

        // Text hierarchy
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        private static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Typography {
        static let titleSize: CGFloat = 14
        static let sectionHeaderSize: CGFloat = 12
        static let bodySize: CGFloat = 12
        static let resetTimeSize: CGFloat = 12
        static let captionSize: CGFloat = 11
        static let microSize: CGFloat = 10
        @MainActor static let chartLabel = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let pill: CGFloat = 999
    }

    enum Shadow {
        static let cardRadius: CGFloat = 4
        static let cardYOffset: CGFloat = 1
    }

    enum Layout {
        static let popoverWidth: CGFloat = 440
        static let settingsWidth: CGFloat = 480
        static let settingsMinHeight: CGFloat = 400
        static let settingsTabIconSize: CGFloat = 16
        static let settingsTabMinWidth: CGFloat = 76
        static let settingsStatusDotSize: CGFloat = 6

        static let headerButtonSize: CGFloat = 26

        static let chartAspectRatio: CGFloat = 16.0 / 9.0
        static let chartGridDivisions: Int = 4
        static let chartLabelHeight: CGFloat = 12
        static let chartLabelGap: CGFloat = 3
        static let chartLabelCollisionGap: CGFloat = 14
        static let chartMarkerSize: CGFloat = 8
        static let legendMarkerSize: CGFloat = 8

        static let resetProviderIconSize: CGFloat = 14
        static let resetMarkerSize: CGFloat = 8
        static let resetListTimeWidth: CGFloat = 60

        static let menuBarRingSize: CGFloat = 13
        static let menuBarRingSpacing: CGFloat = 4

        static let providerDotSize: CGFloat = 8
        static let iconSmallSize: CGFloat = 12
        static let iconMediumSize: CGFloat = 14
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let chartPaceLine = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 4])
        static let chartRingWidth: CGFloat = 1.5
        static let legendRingWidth: CGFloat = 1.5
        static let resetCardAccentWidth: CGFloat = 2
        static let menuBarRingWidth: CGFloat = 2.5
    }

    enum Opacity {
        static let disabledControl: Double = 0.5
    }
}
