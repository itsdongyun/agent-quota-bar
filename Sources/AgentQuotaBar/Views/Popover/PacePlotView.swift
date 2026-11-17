import SwiftUI

/// A marker on a pace plot. `x` is the elapsed fraction of the window, `y` the used fraction (both `0...1`).
struct PacePlotMarker: Identifiable {
    enum Style {
        /// Weekly window.
        case filled
        /// 5-hour or daily window.
        case ring
    }

    let id: String
    let x: Double
    let y: Double
    let color: Color
    let style: Style
    let label: String?
    let help: String
}

/// Square pace plot: over-pace (upper-left) and under-pace (lower-right) zones, a grid,
/// the dashed even-pace diagonal, and usage markers with optional percent labels.
struct PacePlotView: View {
    let markers: [PacePlotMarker]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let labelCenters = placeLabels(in: size)
            ZStack(alignment: .topLeading) {
                background
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))

                ForEach(orderedMarkers) { marker in
                    markerView(marker)
                        .position(position(of: marker, in: size))
                        .help(marker.help)
                }

                ForEach(markers) { marker in
                    if let label = marker.label, let center = labelCenters[marker.id] {
                        Text(label)
                            .font(.system(size: DesignTokens.Typography.chartLabelSize, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .shadow(color: DesignTokens.Colors.chartLabelShadow, radius: DesignTokens.Shadow.chartLabelRadius)
                            .fixedSize()
                            .position(center)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// Rings first so a weekly marker on the same spot stays on top.
    private var orderedMarkers: [PacePlotMarker] {
        markers.filter { $0.style == .ring } + markers.filter { $0.style == .filled }
    }

    private var background: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)

            var underPace = Path()
            underPace.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            underPace.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            underPace.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            underPace.closeSubpath()
            context.fill(underPace, with: .color(DesignTokens.Colors.chartUnderPaceZone))

            var overPace = Path()
            overPace.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            overPace.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            overPace.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            overPace.closeSubpath()
            context.fill(overPace, with: .color(DesignTokens.Colors.chartOverPaceZone))

            let divisions = DesignTokens.Layout.chartGridDivisions
            var grid = Path()
            for step in 0...divisions {
                let fraction = CGFloat(step) / CGFloat(divisions)
                let x = rect.minX + rect.width * fraction
                let y = rect.minY + rect.height * fraction
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(DesignTokens.Colors.chartGridLine), lineWidth: DesignTokens.Stroke.hairline)

            var diagonal = Path()
            diagonal.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            diagonal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.stroke(
                diagonal,
                with: .color(DesignTokens.Colors.chartPaceLine),
                style: StrokeStyle(
                    lineWidth: DesignTokens.Stroke.paceLineWidth,
                    dash: [DesignTokens.Stroke.paceDashLength, DesignTokens.Stroke.paceDashGap]
                )
            )
        }
    }

    @ViewBuilder
    private func markerView(_ marker: PacePlotMarker) -> some View {
        switch marker.style {
        case .filled:
            Circle()
                .fill(marker.color)
                .overlay(
                    Circle().stroke(DesignTokens.Colors.chartMarkerOutline, lineWidth: DesignTokens.Stroke.chartMarkerOutlineWidth)
                )
                .frame(width: DesignTokens.Layout.chartFilledMarkerSize, height: DesignTokens.Layout.chartFilledMarkerSize)
        case .ring:
            Circle()
                .fill(DesignTokens.Colors.chartMarkerOutline)
                .overlay(
                    Circle().strokeBorder(marker.color, lineWidth: DesignTokens.Stroke.chartRingWidth)
                )
                .frame(width: DesignTokens.Layout.chartRingMarkerSize, height: DesignTokens.Layout.chartRingMarkerSize)
        }
    }

    private func position(of marker: PacePlotMarker, in size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(max(0, min(1, marker.x))) * size.width,
            y: CGFloat(1 - max(0, min(1, marker.y))) * size.height
        )
    }

    /// Places each label beside its marker (right, or left near the edge), nudging vertically to avoid overlaps.
    private func placeLabels(in size: CGSize) -> [String: CGPoint] {
        let labelHeight = DesignTokens.Layout.chartLabelHeight
        let collisionGap = DesignTokens.Layout.chartLabelCollisionGap
        let minY = labelHeight / 2
        let maxY = max(minY, size.height - labelHeight / 2)
        var placed: [(center: CGPoint, width: CGFloat)] = []
        var result: [String: CGPoint] = [:]

        for marker in markers {
            guard let label = marker.label else { continue }
            let anchor = position(of: marker, in: size)
            let width = CGFloat(label.count) * DesignTokens.Layout.chartLabelApproxCharWidth
            let offset = DesignTokens.Layout.chartFilledMarkerSize / 2 + DesignTokens.Layout.chartLabelGap + width / 2
            let rightX = anchor.x + offset
            let centerX = rightX + width / 2 <= size.width ? rightX : anchor.x - offset

            var centerY = max(minY, min(maxY, anchor.y))
            for delta in [0, -collisionGap, collisionGap, -2 * collisionGap, 2 * collisionGap] {
                let candidateY = max(minY, min(maxY, anchor.y + delta))
                let collides = placed.contains { existing in
                    abs(centerX - existing.center.x) < (width + existing.width) / 2
                        && abs(candidateY - existing.center.y) < collisionGap
                }
                if !collides {
                    centerY = candidateY
                    break
                }
            }

            let center = CGPoint(x: centerX, y: centerY)
            placed.append((center, width))
            result[marker.id] = center
        }
        return result
    }
}
