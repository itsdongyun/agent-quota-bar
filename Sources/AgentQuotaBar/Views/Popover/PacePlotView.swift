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
        // Room for labels of markers on the top or bottom edge, which stay level with their marker.
        .padding(.vertical, DesignTokens.Layout.chartLabelHeight / 2)
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

    /// A label's wanted spot: level with its marker, on the right unless that overflows.
    private struct LabelSlot {
        let id: String
        let desiredY: CGFloat
        let width: CGFloat
        let onRight: Bool
        /// Edge facing the marker: leading edge for right labels, trailing edge for left labels.
        let edgeX: CGFloat
    }

    /// Places each label beside its marker, level with it. Labels that would overlap are stacked
    /// into one column next to their markers, moved vertically only as far as needed to separate them
    /// and kept in the markers' vertical order, so each label stays at its own marker's height.
    private func placeLabels(in size: CGSize) -> [String: CGPoint] {
        let labelHeight = DesignTokens.Layout.chartLabelHeight
        let inset = DesignTokens.Layout.chartMarkerSize / 2 + DesignTokens.Layout.chartLabelGap

        let slots = markers.map { marker -> LabelSlot in
            let anchor = position(of: marker, in: size)
            let width = marker.label.size(withAttributes: [.font: DesignTokens.Typography.chartLabel]).width
            let onRight = anchor.x + inset + width <= size.width || anchor.x - inset - width < 0
            return LabelSlot(
                id: marker.id,
                desiredY: anchor.y,
                width: width,
                onRight: onRight,
                edgeX: onRight ? anchor.x + inset : anchor.x - inset
            )
        }

        func layout(_ group: [LabelSlot]) -> [(slot: LabelSlot, rect: CGRect)] {
            let sorted = group.sorted { $0.desiredY < $1.desiredY }
            let span = CGFloat(sorted.count - 1) * labelHeight
            let meanY = sorted.map(\.desiredY).reduce(0, +) / CGFloat(sorted.count)
            let topY = max(0, min(size.height - span, meanY - span / 2))
            // Within a stack, labels share the column edge clear of every marker in it.
            let rightEdge = sorted.filter(\.onRight).map(\.edgeX).max() ?? 0
            let leftEdge = sorted.filter { !$0.onRight }.map(\.edgeX).min() ?? 0
            return sorted.enumerated().map { index, slot in
                let minX = slot.onRight ? rightEdge : leftEdge - slot.width
                let centerY = topY + CGFloat(index) * labelHeight
                return (slot, CGRect(x: minX, y: centerY - labelHeight / 2, width: slot.width, height: labelHeight))
            }
        }

        func overlaps(_ a: [LabelSlot], _ b: [LabelSlot]) -> Bool {
            let aRects = layout(a).map(\.rect)
            return layout(b).contains { placed in
                aRects.contains { $0.insetBy(dx: 0.5, dy: 0.5).intersects(placed.rect.insetBy(dx: 0.5, dy: 0.5)) }
            }
        }

        var groups: [[LabelSlot]] = []
        for slot in slots.sorted(by: { $0.desiredY < $1.desiredY }) {
            var current = [slot]
            // Keep merging until the growing stack no longer overlaps any other stack.
            while let index = groups.firstIndex(where: { overlaps($0, current) }) {
                current += groups.remove(at: index)
            }
            groups.append(current)
        }

        var result: [String: CGPoint] = [:]
        for group in groups {
            for (slot, rect) in layout(group) {
                result[slot.id] = CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        return result
    }
}
