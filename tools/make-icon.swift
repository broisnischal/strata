// Draws Strata's app icon and writes the AppIcon asset set.
// Usage: swift tools/make-icon.swift <AppIcon.appiconset> [neon hex]
//
// Three graphite glass slabs, the Mac in layers (processes, drivers, files),
// and one neon pulse running across the top one. Everything is monochrome
// except the pulse and the light it throws.

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let neon: UInt32 = args.dropFirst().first.flatMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0x3CF0FF

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// macOS's icon shape: a superellipse in the 824-point body of the 1024 grid.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let (cx, cy, rx, ry) = (rect.midX, rect.midY, rect.width / 2, rect.height / 2)
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let x = cx + rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

func linear(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGFloat, CGColor)], from p0: CGPoint, to p1: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, clip: CGPath, center: CGPoint, radius: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

/// One slab: a face, two sides, and the rim light along its edges.
struct Slab {
    let cy: CGFloat
    let face: (UInt32, UInt32)
    let left: UInt32, right: UInt32
    let rim: CGFloat
}

let a: CGFloat = 262, b: CGFloat = 131, thickness: CGFloat = 30, cx: CGFloat = 512

func draw(_ ctx: CGContext) {
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x09090B))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, shape, [(0, rgb(0x1E1E22)), (0.55, rgb(0x0E0E10)), (1, rgb(0x060607))], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    // The neon lights the room a little.
    radial(ctx, clip: shape, center: CGPoint(x: 512, y: 400), radius: 430, neon, 0.16)

    // A hairline where the glass edge of the tile catches the light.
    ctx.saveGState()
    ctx.addPath(squircle(in: body.insetBy(dx: 1.5, dy: 1.5)))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    let slabs = [
        Slab(cy: 616, face: (0x3A3A41, 0x232328), left: 0x141417, right: 0x1C1C20, rim: 0.36),
        Slab(cy: 506, face: (0x4A4A52, 0x2C2C32), left: 0x18181C, right: 0x222227, rim: 0.50),
        Slab(cy: 396, face: (0x5E5E68, 0x33333A), left: 0x1E1E23, right: 0x29292F, rim: 0.80),
    ]
    for (i, s) in slabs.enumerated() {
        let n = CGPoint(x: cx, y: s.cy - b), e = CGPoint(x: cx + a, y: s.cy)
        let so = CGPoint(x: cx, y: s.cy + b), w = CGPoint(x: cx - a, y: s.cy)
        let t = thickness
        let face = polygon([n, e, so, w])
        let left = polygon([w, so, CGPoint(x: so.x, y: so.y + t), CGPoint(x: w.x, y: w.y + t)])
        let right = polygon([so, e, CGPoint(x: e.x, y: e.y + t), CGPoint(x: so.x, y: so.y + t)])
        let whole = polygon([n, e, CGPoint(x: e.x, y: e.y + t), CGPoint(x: so.x, y: so.y + t), CGPoint(x: w.x, y: w.y + t), w])

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 34, color: rgb(0x000000, 0.7))
        ctx.addPath(whole)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(left); ctx.setFillColor(rgb(s.left)); ctx.fillPath()
        ctx.addPath(right); ctx.setFillColor(rgb(s.right)); ctx.fillPath()
        linear(ctx, face, [(0, rgb(s.face.0)), (1, rgb(s.face.1))], from: n, to: so)

        // Rim light: bright on the far edges, a softer line on the near ones.
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addLines(between: [w, n, e])
        ctx.setStrokeColor(rgb(0xFFFFFF, s.rim))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addLines(between: [w, so, e])
        ctx.setStrokeColor(rgb(0xFFFFFF, s.rim * 0.35))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        if i == 2 { pulse(ctx, on: face, cy: s.cy) }
    }
}

/// A neon heartbeat across the top slab: a white-hot core, the tube's colour
/// around it, and a wide glow that spills onto the glass.
func pulse(_ ctx: CGContext, on face: CGPath, cy: CGFloat) {
    let beat: [(CGFloat, CGFloat)] = [
        (-0.80, 0), (-0.40, 0), (-0.29, 0.14), (-0.19, -0.06), (-0.07, 0.66), (0.07, -0.50), (0.19, 0.10), (0.29, 0), (0.80, 0),
    ]
    let points = beat.map { CGPoint(x: cx + $0.0 * a, y: cy - $0.1 * b * 0.8) }
    let line = CGMutablePath()
    line.addLines(between: points)

    // Light thrown on the face, kept inside it.
    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    radial(ctx, clip: face, center: CGPoint(x: cx, y: cy), radius: 240, neon, 0.30)
    ctx.restoreGState()

    func stroke(_ width: CGFloat, _ color: CGColor, glow: CGFloat = 0, glowColor: CGColor? = nil) {
        ctx.saveGState()
        if glow > 0, let glowColor { ctx.setShadow(offset: .zero, blur: glow, color: glowColor) }
        ctx.addPath(line)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        ctx.strokePath()
        ctx.restoreGState()
    }
    stroke(30, rgb(neon, 0.18), glow: 60, glowColor: rgb(neon, 0.9))
    stroke(18, rgb(neon, 0.95), glow: 22, glowColor: rgb(neon, 1))
    stroke(6, rgb(0xFFFFFF, 0.92))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args.first ?? "AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: point * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(out.path)")
