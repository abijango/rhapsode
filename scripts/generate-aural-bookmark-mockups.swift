#!/usr/bin/env swift
import AppKit
import CoreGraphics

let side: CGFloat = 1024
let output = FileManager.default.currentDirectoryPath + "/icon-mockups-v2"
let cs = CGColorSpaceCreateDeviceRGB()

func cg(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func makeBitmap(width: Int = 1024, height: Int = 1024) -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return (ctx, rep)
}

func gradient(_ ctx: CGContext, colors: [UInt32], locations: [CGFloat], start: CGPoint, end: CGPoint) {
    let g = CGGradient(
        colorsSpace: cs,
        colors: colors.map { cg($0) } as CFArray,
        locations: locations
    )!
    ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, inner: UInt32, outer: UInt32, center: CGPoint, radius: CGFloat, alpha: CGFloat = 1) {
    let g = CGGradient(
        colorsSpace: cs,
        colors: [cg(inner, alpha: alpha), cg(outer, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func bookmarkPath(rect: CGRect, notchDepth: CGFloat, wave: Bool = false) -> CGPath {
    let p = CGMutablePath()
    let r = min(rect.width * 0.18, 88)
    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 18))
    if wave {
        p.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY - notchDepth),
            control1: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY - 12),
            control2: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.maxY - notchDepth)
        )
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - 18),
            control1: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.maxY - notchDepth),
            control2: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - 12)
        )
    } else {
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notchDepth))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 18))
    }
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    return p
}

func fill(_ ctx: CGContext, _ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
    ctx.addPath(path)
    ctx.setFillColor(cg(hex, alpha: alpha))
    ctx.fillPath()
}

func stroke(_ ctx: CGContext, _ path: CGPath, _ hex: UInt32, width: CGFloat, alpha: CGFloat = 1) {
    ctx.addPath(path)
    ctx.setStrokeColor(cg(hex, alpha: alpha))
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func withShadow(_ ctx: CGContext, color: UInt32, alpha: CGFloat, blur: CGFloat, y: CGFloat, draw: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: cg(color, alpha: alpha))
    draw()
    ctx.restoreGState()
}

func conceptEditorial(_ ctx: CGContext) {
    gradient(ctx, colors: [0x7B243F, 0x3C1530, 0x171229], locations: [0, 0.56, 1],
             start: CGPoint(x: 160, y: 80), end: CGPoint(x: 860, y: 970))
    radial(ctx, inner: 0xD05B60, outer: 0x3C1530, center: CGPoint(x: 300, y: 250), radius: 520, alpha: 0.30)

    let back = bookmarkPath(rect: CGRect(x: 310, y: 192, width: 404, height: 650), notchDepth: 118, wave: true)
    withShadow(ctx, color: 0x130817, alpha: 0.42, blur: 46, y: 28) {
        gradientClipped(ctx, path: back, colors: [0xFFCC92, 0xE96E5D], startY: 180, endY: 850)
    }
    stroke(ctx, back, 0xFFE2BA, width: 6, alpha: 0.30)

    let aperture = CGPath(roundedRect: CGRect(x: 437, y: 374, width: 150, height: 54),
                          cornerWidth: 27, cornerHeight: 27, transform: nil)
    fill(ctx, aperture, 0x4A1831, alpha: 0.82)
    let dot = CGPath(ellipseIn: CGRect(x: 484, y: 482, width: 56, height: 56), transform: nil)
    fill(ctx, dot, 0xFFF1D9, alpha: 0.90)
}

func conceptLiterary(_ ctx: CGContext) {
    gradient(ctx, colors: [0x274968, 0x182A4A, 0x10162F], locations: [0, 0.55, 1],
             start: CGPoint(x: 120, y: 90), end: CGPoint(x: 880, y: 950))
    radial(ctx, inner: 0x5DA7B6, outer: 0x182A4A, center: CGPoint(x: 512, y: 320), radius: 500, alpha: 0.26)

    let rear = bookmarkPath(rect: CGRect(x: 288, y: 225, width: 340, height: 620), notchDepth: 100)
    withShadow(ctx, color: 0x080D1C, alpha: 0.45, blur: 44, y: 30) {
        fill(ctx, rear, 0x92C9C1, alpha: 0.70)
    }

    let front = bookmarkPath(rect: CGRect(x: 416, y: 162, width: 330, height: 650), notchDepth: 126, wave: true)
    withShadow(ctx, color: 0x080D1C, alpha: 0.38, blur: 36, y: 22) {
        gradientClipped(ctx, path: front, colors: [0xFFF4DD, 0xF2C8A8], startY: 150, endY: 820)
    }
    stroke(ctx, front, 0xFFFFFF, width: 5, alpha: 0.32)

    let ripple1 = CGPath(ellipseIn: CGRect(x: 498, y: 326, width: 166, height: 166), transform: nil)
    let ripple2 = CGPath(ellipseIn: CGRect(x: 535, y: 363, width: 92, height: 92), transform: nil)
    stroke(ctx, ripple1, 0x2B5363, width: 24, alpha: 0.72)
    fill(ctx, ripple2, 0xE96E5D, alpha: 0.92)
}

func conceptQuietGlass(_ ctx: CGContext) {
    gradient(ctx, colors: [0x6553A1, 0x3D3476, 0x222044], locations: [0, 0.58, 1],
             start: CGPoint(x: 130, y: 70), end: CGPoint(x: 880, y: 970))
    radial(ctx, inner: 0xB6A3F2, outer: 0x3D3476, center: CGPoint(x: 310, y: 260), radius: 560, alpha: 0.23)

    let outer = bookmarkPath(rect: CGRect(x: 292, y: 176, width: 440, height: 680), notchDepth: 142, wave: true)
    withShadow(ctx, color: 0x171329, alpha: 0.44, blur: 52, y: 30) {
        fill(ctx, outer, 0xE9E2FF, alpha: 0.74)
    }
    stroke(ctx, outer, 0xFFFFFF, width: 7, alpha: 0.38)

    let inner = bookmarkPath(rect: CGRect(x: 386, y: 266, width: 252, height: 452), notchDepth: 82, wave: true)
    gradientClipped(ctx, path: inner, colors: [0xFFAD8F, 0xF07072], startY: 250, endY: 730)

    let slot = CGPath(roundedRect: CGRect(x: 473, y: 357, width: 78, height: 185),
                      cornerWidth: 39, cornerHeight: 39, transform: nil)
    fill(ctx, slot, 0x342B67, alpha: 0.84)
}

func gradientClipped(_ ctx: CGContext, path: CGPath, colors: [UInt32], startY: CGFloat, endY: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    gradient(ctx, colors: colors, locations: [0, 1],
             start: CGPoint(x: 512, y: startY), end: CGPoint(x: 512, y: endY))
    ctx.restoreGState()
}

func save(_ rep: NSBitmapImageRep, name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let concepts: [(String, (CGContext) -> Void)] = [
    ("01-editorial-bookmark", conceptEditorial),
    ("02-layered-story", conceptLiterary),
    ("03-quiet-glass", conceptQuietGlass)
]

var rendered: [NSImage] = []
for (name, draw) in concepts {
    let (ctx, rep) = makeBitmap()
    draw(ctx)
    save(rep, name: name)
    rendered.append(NSImage(data: rep.representation(using: .png, properties: [:])!)!)
}

let boardW = 3400
let boardH = 1320
let (board, boardRep) = makeBitmap(width: boardW, height: boardH)
board.setFillColor(cg(0xE9E8EF))
board.fill(CGRect(x: 0, y: 0, width: boardW, height: boardH))

for (index, image) in rendered.enumerated() {
    let x = CGFloat(120 + index * 1100)
    let frame = CGRect(x: x, y: 120, width: 980, height: 980)
    let mask = CGPath(roundedRect: frame, cornerWidth: 218, cornerHeight: 218, transform: nil)
    board.saveGState()
    board.setShadow(offset: CGSize(width: 0, height: 22), blur: 38, color: cg(0x171522, alpha: 0.25))
    board.addPath(mask)
    board.clip()
    NSGraphicsContext.saveGraphicsState()
    board.translateBy(x: 0, y: CGFloat(boardH))
    board.scaleBy(x: 1, y: -1)
    image.draw(in: CGRect(x: x, y: CGFloat(boardH) - frame.maxY, width: 980, height: 980))
    NSGraphicsContext.restoreGraphicsState()
    board.restoreGState()
}
save(boardRep, name: "comparison")
print("Saved Aural Bookmark mockups to \(output)")
