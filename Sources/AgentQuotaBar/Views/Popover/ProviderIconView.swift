import AppKit
import SwiftUI
import AgentQuotaCore

/// Renders a provider's bundled icon, tinting monochrome template assets with `tintColor`.
struct ProviderIconView: View {
    let provider: ProviderID
    let size: CGFloat
    var tintColor: Color = DesignTokens.Colors.textPrimary

    var body: some View {
        let iconName = NSImage.Name("provider-\(provider.rawValue)")
        if let icon = Bundle.module.image(forResource: iconName) {
            Image(nsImage: icon)
                .renderingMode(provider == .codex ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tintColor)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
