// Draws Strata's app icon and writes the AppIcon asset set.
// Usage: swift tools/make-icon.swift Strata/Assets.xcassets/AppIcon.appiconset
//
// Three slabs, the Mac in layers (processes, drivers, files), with a pulse
// running across the top one. Colours are the app's own series palette.

import AppKit
import CoreGraphics

let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

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

func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

struct Slab {
    let cy: CGFloat
    let faceTop: UInt32, faceBottom: UInt32, left: UInt32, right: UInt32
    var faceAlpha: CGFloat = 1
}

let a: CGFloat = 262, b: CGFloat = 131, thickness: CGFloat = 34, cx: CGFloat = 512

func draw(_ ctx: CGContext) {
    // Top-left origin, like the design grid.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // The icon's own drop shadow, then the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.38))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0B1020))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, shape, top: rgb(0x22305A), bottom: rgb(0x0A0E1C), from: 100, to: 924)

    // A soft glow behind the stack.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x3987E5, 0.45), rgb(0x3987E5, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 380), startRadius: 0, endCenter: CGPoint(x: 512, y: 380), endRadius: 470, options: [])
    ctx.restoreGState()

    let slabs = [
        Slab(cy: 618, faceTop: 0x7A6CF0, faceBottom: 0x5243C9, left: 0x2E2580, right: 0x3A2FA0),
        Slab(cy: 506, faceTop: 0x4B97F0, faceBottom: 0x2367C2, left: 0x14457F, right: 0x1A5498),
        Slab(cy: 394, faceTop: 0xFFFFFF, faceBottom: 0xD6E5FA, left: 0x8EA9D2, right: 0xA9C1E4, faceAlpha: 0.97),
    ]
    for (i, s) in slabs.enumerated() {
        let n = CGPoint(x: cx, y: s.cy - b), e = CGPoint(x: cx + a, y: s.cy)
        let so = CGPoint(x: cx, y: s.cy + b), w = CGPoint(x: cx - a, y: s.cy)
        let t = thickness
        let face = polygon([n, e, so, w])
        let left = polygon([w, so, CGPoint(x: so.x, y: so.y + t), CGPoint(x: w.x, y: w.y + t)])
        let right = polygon([so, e, CGPoint(x: e.x, y: e.y + t), CGPoint(x: so.x, y: so.y + t)])
        let whole = polygon([n, e, CGPoint(x: e.x, y: e.y + t), CGPoint(x: so.x, y: so.y + t), CGPoint(x: w.x, y: w.y + t), w])

        // Each slab's shadow falls on the one below.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: rgb(0x000000, 0.45))
        ctx.addPath(whole)
        ctx.setFillColor(rgb(0x000000, 0.9))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(left); ctx.setFillColor(rgb(s.left)); ctx.fillPath()
        ctx.addPath(right); ctx.setFillColor(rgb(s.right)); ctx.fillPath()
        fill(ctx, face, top: rgb(s.faceTop, s.faceAlpha), bottom: rgb(s.faceBottom, s.faceAlpha), from: n.y, to: so.y)

        // A lit edge along the far sides of the face.
        ctx.saveGState()
        ctx.addLines(between: [w, n, e])
        ctx.setStrokeColor(rgb(0xFFFFFF, i == 2 ? 0.9 : 0.35))
        ctx.setLineWidth(3)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()

        if i == 2 { pulse(ctx, on: face, cy: s.cy) }
    }
}

/// A heartbeat across the top slab, squashed onto its plane.
func pulse(_ ctx: CGContext, on face: CGPath, cy: CGFloat) {
    let beat: [(CGFloat, CGFloat)] = [
        (-1.0, 0), (-0.42, 0), (-0.30, 0.14), (-0.20, -0.06), (-0.08, 0.62), (0.06, -0.46), (0.18, 0.10), (0.28, 0), (1.0, 0),
    ]
    let points = beat.map { CGPoint(x: cx + $0.0 * a * 0.86, y: cy - $0.1 * b * 0.78) }
    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: points)
    ctx.setStrokeColor(rgb(0xEB6834, 0.25))
    ctx.setLineWidth(34)
    ctx.strokePath()
    ctx.addLines(between: points)
    ctx.setStrokeColor(rgb(0xEB6834))
    ctx.setLineWidth(17)
    ctx.strokePath()
    ctx.restoreGState()
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

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset", isDirectory: true)
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
