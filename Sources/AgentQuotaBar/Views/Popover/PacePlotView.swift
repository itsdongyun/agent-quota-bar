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
        let label: String
        let anchor: CGPoint
        let desiredY: CGFloat
        let width: CGFloat
    }

    /// Places each label beside its marker, level with it. Overlapping labels are grouped into one
    /// column clear of their markers; identical labels in the same group collapse into a single
    /// label instead of stacking duplicate percentages, while distinct labels stack in vertical order.
    private func placeLabels(in size: CGSize) -> [String: CGPoint] {
        let labelHeight = DesignTokens.Layout.chartLabelHeight
        let markerRadius = DesignTokens.Layout.chartMarkerSize / 2
        let labelGap = DesignTokens.Layout.chartLabelGap
        let inset = markerRadius + labelGap

        let slots = markers.map { marker -> LabelSlot in
            let anchor = position(of: marker, in: size)
            let width = marker.label.size(withAttributes: [.font: DesignTokens.Typography.chartLabel]).width
            return LabelSlot(
                id: marker.id,
                label: marker.label,
                anchor: anchor,
                desiredY: anchor.y,
                width: width
            )
        }

        func markerRect(for slot: LabelSlot) -> CGRect {
            CGRect(
                x: slot.anchor.x - inset,
                y: slot.anchor.y - markerRadius,
                width: inset * 2,
                height: DesignTokens.Layout.chartMarkerSize
            )
        }

        func layout(_ group: [LabelSlot]) -> [(id: String, rect: CGRect)] {
            var indexByLabel: [String: Int] = [:]
            var collapsed: [(id: String, sumY: CGFloat, count: Int, width: CGFloat)] = []
            for slot in group.sorted(by: { $0.desiredY < $1.desiredY }) {
                if let index = indexByLabel[slot.label] {
                    collapsed[index].sumY += slot.desiredY
                    collapsed[index].count += 1
                } else {
                    indexByLabel[slot.label] = collapsed.count
                    collapsed.append((slot.id, slot.desiredY, 1, slot.width))
                }
            }
            let visible = collapsed
                .map { (id: $0.id, desiredY: $0.sumY / CGFloat($0.count), width: $0.width) }
                .sorted { $0.desiredY < $1.desiredY }

            let span = CGFloat(visible.count - 1) * labelHeight
            let meanY = visible.map(\.desiredY).reduce(0, +) / CGFloat(visible.count)
            let topY = max(0, min(size.height - span, meanY - span / 2))

            // Keep the label column clear of every marker in the group.
            let maxAnchorX = group.map(\.anchor.x).max() ?? 0
            let minAnchorX = group.map(\.anchor.x).min() ?? 0
            let maxWidth = visible.map(\.width).max() ?? 0
            let placeOnRight = maxAnchorX + inset + maxWidth <= size.width || minAnchorX - inset - maxWidth < 0
            let rightEdge = maxAnchorX + inset
            let leftEdge = minAnchorX - inset

            return visible.enumerated().map { index, item in
                let minX = placeOnRight ? rightEdge : leftEdge - item.width
                let centerY = topY + CGFloat(index) * labelHeight
                return (item.id, CGRect(x: minX, y: centerY - labelHeight / 2, width: item.width, height: labelHeight))
            }
        }

        func intersectsAny(_ rects: [CGRect], _ targets: [CGRect]) -> Bool {
            rects.contains { rect in
                targets.contains { $0.insetBy(dx: 0.5, dy: 0.5).intersects(rect.insetBy(dx: 0.5, dy: 0.5)) }
            }
        }

        func overlaps(_ a: [LabelSlot], _ b: [LabelSlot]) -> Bool {
            let aRects = layout(a).map(\.rect)
            let bRects = layout(b).map(\.rect)
            return intersectsAny(aRects, bRects)
                || intersectsAny(aRects, b.map(markerRect))
                || intersectsAny(bRects, a.map(markerRect))
        }

        var groups: [[LabelSlot]] = []
        for slot in slots.sorted(by: { $0.desiredY < $1.desiredY }) {
            var current = [slot]
            // Keep merging until the growing stack no longer overlaps any other stack or marker.
            while let index = groups.firstIndex(where: { overlaps($0, current) }) {
                current += groups.remove(at: index)
            }
            groups.append(current)
        }

        var result: [String: CGPoint] = [:]
        for group in groups {
            for (id, rect) in layout(group) {
                result[id] = CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        return result
    }
}
