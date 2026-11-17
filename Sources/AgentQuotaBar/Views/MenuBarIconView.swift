import AppKit
import SwiftUI
import AgentQuotaCore

/// One provider ring in the menu bar: progress of its most pressing window.
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
    let rings: [MenuBarRing]
    let accessibilityText: String

    var body: some View {
        if rings.isEmpty {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .accessibilityLabel(accessibilityText)
        } else {
            Image(nsImage: renderedImage)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var renderedImage: NSImage {
        let renderer = ImageRenderer(content: MenuBarRingsView(rings: rings))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}

private struct MenuBarRingsView: View {
    let rings: [MenuBarRing]

    var body: some View {
        HStack(spacing: DesignTokens.Layout.menuBarRingSpacing) {
            ForEach(rings) { ring in
                ZStack {
                    Circle()
                        .stroke(DesignTokens.Colors.menuBarRingTrack, lineWidth: DesignTokens.Stroke.menuBarRingWidth)
                    if let fraction = ring.fraction {
                        Circle()
                            .trim(from: 0, to: max(0, min(1, fraction)))
                            .stroke(
                                ring.color,
                                style: StrokeStyle(lineWidth: DesignTokens.Stroke.menuBarRingWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: DesignTokens.Layout.menuBarRingSize, height: DesignTokens.Layout.menuBarRingSize)
                .padding(DesignTokens.Stroke.menuBarRingWidth / 2)
            }
        }
    }
}
