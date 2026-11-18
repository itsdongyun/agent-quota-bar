import AppKit
import SwiftUI
import AgentQuotaCore

/// How the menu bar item looks. Persisted by raw value, so keep the cases' raw values stable.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// A single app icon.
    case icon
    /// One usage ring per provider.
    case rings
    /// One usage ring per provider with its percentage inside (default).
    case ringsWithPercent

    var id: String { rawValue }

    var title: String {
        L10n.string("settings.menu_bar_style.\(rawValue)")
    }
}

/// One provider ring in the menu bar: progress of its short-term (5-hour or daily) window.
struct MenuBarRing: Identifiable {
    let provider: ProviderID
    /// Used fraction `0...1`; `nil` draws only the track (no data yet).
    let fraction: Double?
    let color: Color

    var id: ProviderID { provider }
}

/// Menu bar label: one usage ring per enabled provider, always in the provider's color, with no background.
/// Rendered to a non-template image so the provider colors survive in the menu bar.
struct MenuBarIconView: View {
    let style: MenuBarStyle
    let rings: [MenuBarRing]
    let accessibilityText: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if style == .icon || rings.isEmpty {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .accessibilityLabel(accessibilityText)
        } else {
            Image(nsImage: renderedImage)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var renderedImage: NSImage {
        // The image is not a template, so the percent text must follow the menu bar's appearance explicitly.
        let renderer = ImageRenderer(content: MenuBarRingsView(rings: rings, showsPercent: style == .ringsWithPercent).environment(\.colorScheme, colorScheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}

private struct MenuBarRingsView: View {
    let rings: [MenuBarRing]
    let showsPercent: Bool

    private var ringSize: CGFloat {
        showsPercent ? DesignTokens.Layout.menuBarLabeledRingSize : DesignTokens.Layout.menuBarRingSize
    }

    private var ringWidth: CGFloat {
        showsPercent ? DesignTokens.Stroke.menuBarLabeledRingWidth : DesignTokens.Stroke.menuBarRingWidth
    }

    var body: some View {
        HStack(spacing: DesignTokens.Layout.menuBarRingSpacing) {
            ForEach(rings) { ring in
                ZStack {
                    Circle()
                        .stroke(DesignTokens.Colors.menuBarRingTrack, lineWidth: ringWidth)
                    if let fraction = ring.fraction {
                        Circle()
                            .trim(from: 0, to: max(0, min(1, fraction)))
                            .stroke(
                                ring.color,
                                style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        if showsPercent {
                            Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))")
                                .font(.system(size: DesignTokens.Typography.menuBarRingLabelSize, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(DesignTokens.Colors.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(DesignTokens.Typography.menuBarRingLabelMinScale)
                                .padding(ringWidth)
                        }
                    }
                }
                .frame(width: ringSize, height: ringSize)
                .padding(ringWidth / 2)
            }
        }
    }
}
