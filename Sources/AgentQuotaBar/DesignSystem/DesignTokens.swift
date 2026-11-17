import AppKit
import SwiftUI
import AgentQuotaCore

/// Centralized design tokens for colors, spacing, typography, radii, shadows, and chart geometry.
/// All UI views must style exclusively via these tokens.
enum DesignTokens {
    enum Colors {
        // Provider accents: solid for weekly markers, light for 5-hour/daily rings.
        static let claude = Color(red: 0.94, green: 0.56, blue: 0.38)
        static let codex = Color(red: 0.38, green: 0.65, blue: 0.96)
        static let antigravity = Color(red: 0.30, green: 0.78, blue: 0.47)
        static let claudeLight = Color(red: 0.98, green: 0.80, blue: 0.68)
        static let codexLight = Color(red: 0.72, green: 0.85, blue: 0.99)
        static let antigravityLight = Color(red: 0.72, green: 0.92, blue: 0.78)

        static func provider(_ id: ProviderID) -> Color {
            switch id {
            case .claude: return claude
            case .codex: return codex
            case .antigravity: return antigravity
            }
        }

        static func providerLight(_ id: ProviderID) -> Color {
            switch id {
            case .claude: return claudeLight
            case .codex: return codexLight
            case .antigravity: return antigravityLight
            }
        }

        // Semantic status colors
        static let statusHealthy = Color.green
        static let statusWarning = dynamic(
            light: NSColor(red: 0.80, green: 0.55, blue: 0.00, alpha: 1),
            dark: NSColor(red: 0.96, green: 0.78, blue: 0.30, alpha: 1)
        )
        static let statusCritical = dynamic(
            light: NSColor(red: 0.84, green: 0.26, blue: 0.22, alpha: 1),
            dark: NSColor(red: 0.93, green: 0.42, blue: 0.37, alpha: 1)
        )
        static let statusNeutral = Color.secondary

        static func paceLevel(_ level: PaceLevel) -> Color {
            switch level {
            case .normal: return textPrimary
            case .warning: return statusWarning
            case .critical: return statusCritical
            }
        }

        // Surface & border colors
        static let cardBackground = Color.primary.opacity(0.05)
        static let nestedCardBackground = Color.primary.opacity(0.05)
        static let controlBackground = Color.primary.opacity(0.07)
        static let controlSelectedBackground = Color.primary.opacity(0.14)
        static let borderSubtle = Color.primary.opacity(0.10)
        static let badgeBackground = Color.accentColor.opacity(0.14)
        static let badgeBorder = Color.accentColor.opacity(0.32)
        static let shadowColor = Color.black.opacity(0.12)

        // Pace chart
        static let chartOverPaceZone = statusCritical.opacity(0.12)
        static let chartUnderPaceZone = Color(red: 0.45, green: 0.62, blue: 0.68).opacity(0.10)
        static let chartGridLine = Color.primary.opacity(0.08)
        static let chartPaceLine = Color.primary.opacity(0.45)
        static let chartMarkerOutline = Color(nsColor: .windowBackgroundColor)
        static let chartLabelShadow = Color.black.opacity(0.55)
        static let legendMarker = Color.secondary

        // Menu bar rings
        static let menuBarRingTrack = Color.gray.opacity(0.45)

        // Text hierarchy
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textOnBadge = Color.accentColor

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
        static let popoverTitleSize: CGFloat = 16
        static let titleSize: CGFloat = 14
        static let sectionHeaderSize: CGFloat = 12
        static let bodySize: CGFloat = 12
        static let chipSize: CGFloat = 13
        static let chartCardTitleSize: CGFloat = 11
        static let tableNameSize: CGFloat = 13
        static let tablePercentSize: CGFloat = 14
        static let tableTimeSize: CGFloat = 13
        static let captionSize: CGFloat = 11
        static let microSize: CGFloat = 10
        static let chartLabelSize: CGFloat = 11
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
        static let chartLabelRadius: CGFloat = 2
    }

    enum Layout {
        static let popoverWidth: CGFloat = 380
        static let settingsWidth: CGFloat = 460
        static let settingsMinHeight: CGFloat = 420

        static let headerButtonSize: CGFloat = 26
        static let segmentButtonWidth: CGFloat = 30
        static let segmentButtonHeight: CGFloat = 24
        static let chipHorizontalPadding: CGFloat = 10
        static let chipVerticalPadding: CGFloat = 5

        /// Per-provider plots shown three across.
        static let providerPlotHeight: CGFloat = 72
        /// A single provider plot spanning the full card (provider filter applied).
        static let singlePlotHeight: CGFloat = 120
        /// The 5h·daily and weekly plots shown two across.
        static let windowPlotHeight: CGFloat = 150
        static let chartGridDivisions: Int = 4
        static let chartLabelHeight: CGFloat = 14
        static let chartLabelApproxCharWidth: CGFloat = 7
        static let chartLabelGap: CGFloat = 4
        static let chartLabelCollisionGap: CGFloat = 16
        static let chartFilledMarkerSize: CGFloat = 11
        static let chartRingMarkerSize: CGFloat = 10
        static let legendMarkerSize: CGFloat = 8
        static let legendDashWidth: CGFloat = 14

        static let tableMarkerSize: CGFloat = 9
        static let tablePercentWidth: CGFloat = 36
        static let tableStatusMaxWidth: CGFloat = 200

        static let mockControlWidth: CGFloat = 440
        static let mockControlMinHeight: CGFloat = 560
        static let mockPresetColumns: Int = 4
        static let mockValueLabelWidth: CGFloat = 44

        static let menuBarRingSize: CGFloat = 13
        static let menuBarRingSpacing: CGFloat = 4

        static let providerDotSize: CGFloat = 8
        static let iconSmallSize: CGFloat = 12
        static let iconMediumSize: CGFloat = 14
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let paceLineWidth: CGFloat = 1
        static let paceDashLength: CGFloat = 3
        static let paceDashGap: CGFloat = 3
        static let chartRingWidth: CGFloat = 2.5
        static let chartMarkerOutlineWidth: CGFloat = 2
        static let legendRingWidth: CGFloat = 1.5
        static let menuBarRingWidth: CGFloat = 2.5
    }

    enum Opacity {
        static let disabledControl: Double = 0.5
    }
}
