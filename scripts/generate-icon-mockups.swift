#!/usr/bin/env swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = FileManager.default.currentDirectoryPath + "/icon-mockups"
let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func context(width: Int = 1024, height: Int = 1024) -> (CGContext, NSBitmapImageRep) {
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

func gradient(_ ctx: CGContext, top: UInt32, bottom: UInt32, rect: CGRect) {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(top), color(bottom)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
}

func fill(_ ctx: CGContext, _ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
    ctx.addPath(path)
    ctx.setFillColor(color(hex, alpha))
    ctx.fillPath()
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func pill(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, hex: UInt32) {
    fill(ctx, rounded(CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height), radius: width / 2), hex)
}

func chevron(_ center: CGPoint, pointingRight: Bool) -> CGPath {
    let p = CGMutablePath()
    let direction: CGFloat = pointingRight ? 1 : -1
    p.move(to: CGPoint(x: center.x - direction * 42, y: center.y - 66))
    p.addLine(to: CGPoint(x: center.x + direction * 24, y: center.y))
    p.addLine(to: CGPoint(x: center.x - direction * 42, y: center.y + 66))
    p.addLine(to: CGPoint(x: center.x - direction * 2, y: center.y + 66))
    p.addLine(to: CGPoint(x: center.x + direction * 64, y: center.y))
    p.addLine(to: CGPoint(x: center.x - direction * 2, y: center.y - 66))
    p.closeSubpath()
    return p
}

func drawCollapsedSilence(_ ctx: CGContext) {
    gradient(ctx, top: 0x342A78, bottom: 0x15132E, rect: CGRect(x: 0, y: 0, width: size, height: size))

    let coral: UInt32 = 0xFF7066
    let cream: UInt32 = 0xFFF4E6
    let centerY: CGFloat = 512
    let heights: [CGFloat] = [130, 245, 360, 280, 280, 360, 245, 130]
    let xs: [CGFloat] = [202, 286, 370, 446, 578, 654, 738, 822]
    for (index, x) in xs.enumerated() {
        pill(ctx, x: x, y: centerY, width: 52, height: heights[index], hex: coral)
    }

    fill(ctx, chevron(CGPoint(x: 472, y: centerY), pointingRight: true), cream)
    fill(ctx, chevron(CGPoint(x: 552, y: centerY), pointingRight: false), cream)
}

func drawAudioRibbon(_ ctx: CGContext) {
    gradient(ctx, top: 0x2A2264, bottom: 0x111126, rect: CGRect(x: 0, y: 0, width: size, height: size))

    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 176, y: 596))
    ribbon.addCurve(
        to: CGPoint(x: 420, y: 386),
        control1: CGPoint(x: 248, y: 596),
        control2: CGPoint(x: 322, y: 386)
    )
    ribbon.addCurve(
        to: CGPoint(x: 512, y: 500),
        control1: CGPoint(x: 470, y: 386),
        control2: CGPoint(x: 492, y: 446)
    )
    ribbon.addCurve(
        to: CGPoint(x: 604, y: 386),
        control1: CGPoint(x: 532, y: 446),
        control2: CGPoint(x: 554, y: 386)
    )
    ribbon.addCurve(
        to: CGPoint(x: 848, y: 596),
        control1: CGPoint(x: 702, y: 386),
        control2: CGPoint(x: 776, y: 596)
    )
    ribbon.addLine(to: CGPoint(x: 848, y: 684))
    ribbon.addCurve(
        to: CGPoint(x: 604, y: 474),
        control1: CGPoint(x: 776, y: 684),
        control2: CGPoint(x: 702, y: 474)
    )
    ribbon.addCurve(
        to: CGPoint(x: 512, y: 604),
        control1: CGPoint(x: 554, y: 474),
        control2: CGPoint(x: 532, y: 550)
    )
    ribbon.addCurve(
        to: CGPoint(x: 420, y: 474),
        control1: CGPoint(x: 492, y: 550),
        control2: CGPoint(x: 470, y: 474)
    )
    ribbon.addCurve(
        to: CGPoint(x: 176, y: 684),
        control1: CGPoint(x: 322, y: 474),
        control2: CGPoint(x: 248, y: 684)
    )
    ribbon.closeSubpath()
    fill(ctx, ribbon, 0xFF756B)

    let slit = rounded(CGRect(x: 488, y: 438, width: 48, height: 200), radius: 24)
    fill(ctx, slit, 0xFFF4E6)
}

func drawCadenceSpark(_ ctx: CGContext) {
    gradient(ctx, top: 0x392D82, bottom: 0x17132F, rect: CGRect(x: 0, y: 0, width: size, height: size))

    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 160, y: 534))
    mark.addLine(to: CGPoint(x: 306, y: 534))
    mark.addLine(to: CGPoint(x: 386, y: 350))
    mark.addLine(to: CGPoint(x: 476, y: 666))
    mark.addLine(to: CGPoint(x: 548, y: 448))
    mark.addLine(to: CGPoint(x: 610, y: 574))
    mark.addLine(to: CGPoint(x: 684, y: 426))
    mark.addLine(to: CGPoint(x: 754, y: 534))
    mark.addLine(to: CGPoint(x: 864, y: 534))
    mark.addLine(to: CGPoint(x: 864, y: 606))
    mark.addLine(to: CGPoint(x: 712, y: 606))
    mark.addLine(to: CGPoint(x: 696, y: 582))
    mark.addLine(to: CGPoint(x: 608, y: 758))
    mark.addLine(to: CGPoint(x: 566, y: 672))
    mark.addLine(to: CGPoint(x: 474, y: 850))
    mark.addLine(to: CGPoint(x: 374, y: 498))
    mark.addLine(to: CGPoint(x: 352, y: 606))
    mark.addLine(to: CGPoint(x: 160, y: 606))
    mark.closeSubpath()
    fill(ctx, mark, 0xFF756B)

    let cut = CGMutablePath()
    cut.move(to: CGPoint(x: 482, y: 422))
    cut.addLine(to: CGPoint(x: 542, y: 494))
    cut.addLine(to: CGPoint(x: 482, y: 566))
    cut.closeSubpath()
    fill(ctx, cut, 0xFFF4E6)
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let designs: [(String, (CGContext) -> Void)] = [
    ("01-collapsed-silence", drawCollapsedSilence),
    ("02-audio-ribbon", drawAudioRibbon),
    ("03-cadence-spark", drawCadenceSpark)
]

var images: [NSImage] = []
for (name, draw) in designs {
    let (ctx, rep) = context()
    draw(ctx)
    save(rep, name)
    images.append(NSImage(data: rep.representation(using: .png, properties: [:])!)!)
}

let boardWidth = 3280
let boardHeight = 1200
let (board, boardRep) = context(width: boardWidth, height: boardHeight)
board.setFillColor(color(0xECEAF3))
board.fill(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
for (index, image) in images.enumerated() {
    let x = CGFloat(80 + index * 1080)
    NSGraphicsContext.saveGraphicsState()
    board.translateBy(x: 0, y: CGFloat(boardHeight))
    board.scaleBy(x: 1, y: -1)
    image.draw(in: CGRect(x: x, y: 88, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
}
save(boardRep, "comparison")
print("Saved 3 mockups and comparison sheet to \(output)")
