#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Generates the refined flat, text-free macOS app icon for Agent Quota Bar:
//   - Sources/AgentQuotaBar/Resources/AppIcon.svg
//   - Sources/AgentQuotaBar/Resources/AppIcon.png (1024x1024)
//   - Sources/AgentQuotaBar/Resources/AppIcon.icns
//
// Design: Swiss flat 3-blade tangential aperture on a warm off-white macOS squircle.

struct IconSpec {
    static let canvasSize: CGFloat = 1024
    static let padding: CGFloat = 100
    static let boxSize: CGFloat = canvasSize - padding * 2 // 824

    // Flat Swiss palette
    static let bgHex = "#F6F6F3"
    static let rimHex = "#E2E2DC"
    // Blades: top obsidian ink, left vermilion-coral, bottom-right cobalt-sky
    static let bladeHexes = ["#151820", "#EA5838", "#4B87F5"]

    // Geometry ratios relative to squircle width (824)
    static let outerRadiusRatio: CGFloat = 0.342
    static let innerRadiusRatio: CGFloat = 0.122
    static let gapRatio: CGFloat = 0.036
    // Base orientation so obsidian sits cleanly at top, vermilion on left, cobalt on bottom-right
    static let baseRotationRad: CGFloat = -0.58
    static let rimWidthRatio: CGFloat = 3.0 / 1024.0
}

func hexColor(_ hex: String) -> CGColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let val = UInt64(cleaned, radix: 16) ?? 0
    let r = CGFloat((val >> 16) & 0xFF) / 255.0
    let g = CGFloat((val >> 8) & 0xFF) / 255.0
    let b = CGFloat(val & 0xFF) / 255.0
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}

/// True macOS continuous-curvature squircle path (Apple HIG superellipse corner geometry).
func makeMacOSSquirclePath(in rect: CGRect) -> CGPath {
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
    let r = min(w, h) * 0.2237
    let k1 = r * 1.52866483, k2 = r * 1.08849323, k3 = r * 0.86840689
    let k4 = r * 0.66993427, k6 = r * 0.37282392, k7 = r * 0.16906013, k8 = r * 0.07491176

    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + k1, y: y + h))
    p.addLine(to: CGPoint(x: x + w - k1, y: y + h))
    p.addCurve(to: CGPoint(x: x + w - k4, y: y + h - k8), control1: CGPoint(x: x + w - k2, y: y + h), control2: CGPoint(x: x + w - k3, y: y + h))
    p.addCurve(to: CGPoint(x: x + w - k8, y: y + h - k4), control1: CGPoint(x: x + w - k6, y: y + h - k7), control2: CGPoint(x: x + w - k7, y: y + h - k6))
    p.addCurve(to: CGPoint(x: x + w, y: y + h - k1), control1: CGPoint(x: x + w, y: y + h - k3), control2: CGPoint(x: x + w, y: y + h - k2))
    p.addLine(to: CGPoint(x: x + w, y: y + k1))
    p.addCurve(to: CGPoint(x: x + w - k8, y: y + k4), control1: CGPoint(x: x + w, y: y + k2), control2: CGPoint(x: x + w, y: y + k3))
    p.addCurve(to: CGPoint(x: x + w - k4, y: y + k8), control1: CGPoint(x: x + w - k7, y: y + k6), control2: CGPoint(x: x + w - k6, y: y + k7))
    p.addCurve(to: CGPoint(x: x + w - k1, y: y), control1: CGPoint(x: x + w - k3, y: y), control2: CGPoint(x: x + w - k2, y: y))
    p.addLine(to: CGPoint(x: x + k1, y: y))
    p.addCurve(to: CGPoint(x: x + k4, y: y + k8), control1: CGPoint(x: x + k2, y: y), control2: CGPoint(x: x + k3, y: y))
    p.addCurve(to: CGPoint(x: x + k8, y: y + k4), control1: CGPoint(x: x + k6, y: y + k7), control2: CGPoint(x: x + k7, y: y + k6))
    p.addCurve(to: CGPoint(x: x, y: y + k1), control1: CGPoint(x: x, y: y + k3), control2: CGPoint(x: x, y: y + k2))
    p.addLine(to: CGPoint(x: x, y: y + h - k1))
    p.addCurve(to: CGPoint(x: x + k8, y: y + h - k4), control1: CGPoint(x: x, y: y + h - k2), control2: CGPoint(x: x, y: y + h - k3))
    p.addCurve(to: CGPoint(x: x + k4, y: y + h - k8), control1: CGPoint(x: x + k7, y: y + h - k6), control2: CGPoint(x: x + k6, y: y + h - k7))
    p.addCurve(to: CGPoint(x: x + k1, y: y + h), control1: CGPoint(x: x + k3, y: y + h), control2: CGPoint(x: x + k2, y: y + h))
    p.closeSubpath()
    return p
}

/// Exact uniform-parallel-gap tangential aperture blade geometry in standard math (y-up) coordinates.
struct BladeGeometry {
    let p1: CGPoint // leading inner
    let p2: CGPoint // leading outer
    let p3: CGPoint // trailing outer
    let p4: CGPoint // trailing inner
    let outerStartAngle: CGFloat
    let outerEndAngle: CGFloat
    let innerStartAngle: CGFloat
    let innerEndAngle: CGFloat
    let rOut: CGFloat
    let rIn: CGFloat

    static func compute(rOut: CGFloat, rIn: CGFloat, gap: CGFloat, rotation: CGFloat) -> BladeGeometry {
        let sector: CGFloat = 2.0 * .pi / 3.0
        let xLead = rIn - gap

        // Leading edge (left side of gap 0): x = rIn - gap, y > 0
        let yLeadIn = sqrt(max(0, rIn * rIn - xLead * xLead))
        let yLeadOut = sqrt(max(0, rOut * rOut - xLead * xLead))
        let a1 = atan2(yLeadIn, xLead)
        let a2 = atan2(yLeadOut, xLead)

        // Trailing edge (right side of gap 1, rotated +120 deg): x' = rIn, y' >= 0
        let yTrailOut = sqrt(max(0, rOut * rOut - rIn * rIn))
        let a3 = sector + atan2(yTrailOut, rIn)
        let a4 = sector

        let rotA1 = a1 + rotation
        let rotA2 = a2 + rotation
        let rotA3 = a3 + rotation
        let rotA4 = a4 + rotation

        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: r * cos(a), y: r * sin(a))
        }

        return BladeGeometry(
            p1: pt(rIn, rotA1),
            p2: pt(rOut, rotA2),
            p3: pt(rOut, rotA3),
            p4: pt(rIn, rotA4),
            outerStartAngle: rotA2,
            outerEndAngle: rotA3,
            innerStartAngle: rotA4,
            innerEndAngle: rotA1,
            rOut: rOut,
            rIn: rIn
        )
    }

    func cgPath(center: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x + p1.x, y: center.y + p1.y))
        p.addLine(to: CGPoint(x: center.x + p2.x, y: center.y + p2.y))
        p.addArc(center: center, radius: rOut, startAngle: outerStartAngle, endAngle: outerEndAngle, clockwise: false)
        p.addLine(to: CGPoint(x: center.x + p4.x, y: center.y + p4.y))
        p.addArc(center: center, radius: rIn, startAngle: innerStartAngle, endAngle: innerEndAngle, clockwise: true)
        p.closeSubpath()
        return p
    }
}

func renderIcon(in ctx: CGContext, size: CGFloat) {
    let pad = size * (IconSpec.padding / IconSpec.canvasSize)
    let box = CGRect(x: pad, y: pad, width: size - 2 * pad, height: size - 2 * pad)
    let squircle = makeMacOSSquirclePath(in: box)

    // Warm off-white flat squircle
    ctx.setFillColor(hexColor(IconSpec.bgHex))
    ctx.addPath(squircle)
    ctx.fillPath()

    // Hairline flat inner rim so light squircle stays crisp on white backgrounds
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.setStrokeColor(hexColor(IconSpec.rimHex))
    ctx.setLineWidth(max(1.0, size * IconSpec.rimWidthRatio * 2.0))
    ctx.addPath(squircle)
    ctx.strokePath()
    ctx.restoreGState()

    let s = box.width
    let center = CGPoint(x: box.midX, y: box.midY)
    let rOut = s * IconSpec.outerRadiusRatio
    let rIn = s * IconSpec.innerRadiusRatio
    let gap = s * IconSpec.gapRatio

    for i in 0..<3 {
        let rot = IconSpec.baseRotationRad + CGFloat(i) * (2.0 * .pi / 3.0)
        let blade = BladeGeometry.compute(rOut: rOut, rIn: rIn, gap: gap, rotation: rot)
        ctx.setFillColor(hexColor(IconSpec.bladeHexes[i]))
        ctx.addPath(blade.cgPath(center: center))
        ctx.fillPath()
    }
}

func writePNG(pixelSize: Int, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil,
                              width: pixelSize,
                              height: pixelSize,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "AppIcon", code: 1)
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    renderIcon(in: ctx, size: CGFloat(pixelSize))

    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2)
    }
    try png.write(to: url)
}

func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }

func svgSquirclePath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> String {
    let r = min(w, h) * 0.2237
    let k1 = r * 1.52866483, k2 = r * 1.08849323, k3 = r * 0.86840689
    let k4 = r * 0.66993427, k6 = r * 0.37282392, k7 = r * 0.16906013, k8 = r * 0.07491176

    return [
        "M \(f(x + k1)) \(f(y))",
        "L \(f(x + w - k1)) \(f(y))",
        "C \(f(x + w - k2)) \(f(y)) \(f(x + w - k3)) \(f(y)) \(f(x + w - k4)) \(f(y + k8))",
        "C \(f(x + w - k6)) \(f(y + k7)) \(f(x + w - k7)) \(f(y + k6)) \(f(x + w - k8)) \(f(y + k4))",
        "C \(f(x + w)) \(f(y + k3)) \(f(x + w)) \(f(y + k2)) \(f(x + w)) \(f(y + k1))",
        "L \(f(x + w)) \(f(y + h - k1))",
        "C \(f(x + w)) \(f(y + h - k2)) \(f(x + w)) \(f(y + h - k3)) \(f(x + w - k8)) \(f(y + h - k4))",
        "C \(f(x + w - k7)) \(f(y + h - k6)) \(f(x + w - k6)) \(f(y + h - k7)) \(f(x + w - k4)) \(f(y + h - k8))",
        "C \(f(x + w - k3)) \(f(y + h)) \(f(x + w - k2)) \(f(y + h)) \(f(x + w - k1)) \(f(y + h))",
        "L \(f(x + k1)) \(f(y + h))",
        "C \(f(x + k2)) \(f(y + h)) \(f(x + k3)) \(f(y + h)) \(f(x + k4)) \(f(y + h - k8))",
        "C \(f(x + k6)) \(f(y + h - k7)) \(f(x + k7)) \(f(y + h - k6)) \(f(x + k8)) \(f(y + h - k4))",
        "C \(f(x)) \(f(y + h - k3)) \(f(x)) \(f(y + h - k2)) \(f(x)) \(f(y + h - k1))",
        "L \(f(x)) \(f(y + k1))",
        "C \(f(x)) \(f(y + k2)) \(f(x)) \(f(y + k3)) \(f(x + k8)) \(f(y + k4))",
        "C \(f(x + k7)) \(f(y + k6)) \(f(x + k6)) \(f(y + k7)) \(f(x + k4)) \(f(y + k8))",
        "C \(f(x + k3)) \(f(y)) \(f(x + k2)) \(f(y)) \(f(x + k1)) \(f(y))",
        "Z",
    ].joined(separator: " ")
}

func makeSVG() -> String {
    let s = IconSpec.boxSize
    let pad = IconSpec.padding
    let cx = IconSpec.canvasSize / 2.0
    let cy = IconSpec.canvasSize / 2.0
    let rOut = s * IconSpec.outerRadiusRatio
    let rIn = s * IconSpec.innerRadiusRatio
    let gap = s * IconSpec.gapRatio

    let squircle = svgSquirclePath(x: pad, y: pad, w: s, h: s)
    let rimStroke = IconSpec.canvasSize * IconSpec.rimWidthRatio * 2.0

    var bladePaths: [String] = []
    for i in 0..<3 {
        let rot = IconSpec.baseRotationRad + CGFloat(i) * (2.0 * .pi / 3.0)
        let b = BladeGeometry.compute(rOut: rOut, rIn: rIn, gap: gap, rotation: rot)
        // Convert math y-up to SVG y-down: (cx + pt.x, cy - pt.y)
        // CCW in y-up corresponds to sweep-flag=0 in SVG y-down; CW in y-up corresponds to sweep-flag=1 in SVG y-down.
        let d = [
            "M \(f(cx + b.p1.x)) \(f(cy - b.p1.y))",
            "L \(f(cx + b.p2.x)) \(f(cy - b.p2.y))",
            "A \(f(rOut)) \(f(rOut)) 0 0 0 \(f(cx + b.p3.x)) \(f(cy - b.p3.y))",
            "L \(f(cx + b.p4.x)) \(f(cy - b.p4.y))",
            "A \(f(rIn)) \(f(rIn)) 0 0 1 \(f(cx + b.p1.x)) \(f(cy - b.p1.y))",
            "Z",
        ].joined(separator: " ")
        bladePaths.append("  <path d=\"\(d)\" fill=\"\(IconSpec.bladeHexes[i])\"/>")
    }

    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <defs>
        <clipPath id="squircle-clip">
          <path d="\(squircle)"/>
        </clipPath>
      </defs>
      <path d="\(squircle)" fill="\(IconSpec.bgHex)"/>
      <path d="\(squircle)" fill="none" stroke="\(IconSpec.rimHex)" stroke-width="\(f(rimStroke))" clip-path="url(#squircle-clip)"/>
    \(bladePaths.joined(separator: "\n"))
    </svg>

    """
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesURL = rootURL.appendingPathComponent("Sources/AgentQuotaBar/Resources", isDirectory: true)

let svgURL = resourcesURL.appendingPathComponent("AppIcon.svg")
let pngURL = resourcesURL.appendingPathComponent("AppIcon.png")
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try makeSVG().write(to: svgURL, atomically: true, encoding: .utf8)
try writePNG(pixelSize: 1024, to: pngURL)

let fm = FileManager.default
let tempDir = fm.temporaryDirectory.appendingPathComponent("AgentQuotaBar-AppIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tempDir) }

let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in slots {
    try writePNG(pixelSize: px, to: iconsetURL.appendingPathComponent(filename))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    throw NSError(domain: "AppIcon", code: Int(proc.terminationStatus))
}

print("Generated AppIcon.svg, AppIcon.png, AppIcon.icns")
