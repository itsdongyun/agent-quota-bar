import AppKit
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
    let label: String
    let help: String
}

/// Pace plot with a rectangular grid, a dotted even-pace diagonal, and usage markers.
struct PacePlotView: View {
    let markers: [PacePlotMarker]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let labelCenters = placeLabels(in: size)
            ZStack(alignment: .topLeading) {
                grid

                ForEach(orderedMarkers) { marker in
                    markerView(marker)
                        .position(position(of: marker, in: size))
                        .help(marker.help)
                }

                ForEach(markers) { marker in
                    if let center = labelCenters[marker.id] {
                        Text(marker.label)
                            .font(Font(DesignTokens.Typography.chartLabel))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .fixedSize()
                            .position(center)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .aspectRatio(DesignTokens.Layout.chartAspectRatio, contentMode: .fit)
    }

    /// Rings first so a weekly marker on the same spot stays on top.
    private var orderedMarkers: [PacePlotMarker] {
        markers.filter { $0.style == .ring } + markers.filter { $0.style == .filled }
    }

    private var grid: some View {
        Canvas { context, size in
            let lineInset = DesignTokens.Stroke.hairline / 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineInset, dy: lineInset)
            let divisions = DesignTokens.Layout.chartGridDivisions
            var grid = Path(rect)
            for step in 1..<divisions {
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
                style: DesignTokens.Stroke.chartPaceLine
            )
        }
    }

    private func markerView(_ marker: PacePlotMarker) -> some View {
        Group {
            switch marker.style {
            case .filled:
                Circle().fill(marker.color)
            case .ring:
                Circle().strokeBorder(marker.color, lineWidth: DesignTokens.Stroke.chartRingWidth)
            }
        }
        .frame(width: DesignTokens.Layout.chartMarkerSize, height: DesignTokens.Layout.chartMarkerSize)
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
            let anchor = position(of: marker, in: size)
            let width = marker.label.size(withAttributes: [.font: DesignTokens.Typography.chartLabel]).width
            let offset = DesignTokens.Layout.chartMarkerSize / 2 + DesignTokens.Layout.chartLabelGap + width / 2
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
