#!/usr/bin/env swift
// Generates and installs the production "Editorial Bookmark" Rhapsode icon.

import AppKit
import CoreGraphics
import ImageIO

let size: CGFloat = 1024
let root = FileManager.default.currentDirectoryPath
let catalogDir = root + "/SupportingFiles/Assets.xcassets/AppIcon.appiconset"
let destinations = [
    root + "/icon-variants",
    catalogDir,
    root + "/SupportingFiles/AppIcon.icon/Assets"
]
let colorSpace = CGColorSpaceCreateDeviceRGB()

enum Appearance: String, CaseIterable { case light, dark, tinted }

struct Palette {
    let background: [UInt32]
    let glow: UInt32
    let bookmark: [UInt32]
    let edge: UInt32
    let slot: UInt32
    let dot: UInt32
}

func palette(_ appearance: Appearance) -> Palette {
    switch appearance {
    case .light:
        return Palette(
            background: [0x963B56, 0x551D3B, 0x21152F], glow: 0xDC6A6A,
            bookmark: [0xFFD099, 0xF07C64], edge: 0xFFE2BA,
            slot: 0x5B203B, dot: 0xFFF2DA
        )
    case .dark:
        return Palette(
            background: [0x522037, 0x2A1428, 0x110D1C], glow: 0xA94855,
            bookmark: [0xFFC07F, 0xE65F55], edge: 0xFFD4A8,
            slot: 0x3A1429, dot: 0xFFEBD1
        )
    case .tinted:
        return Palette(
            background: [0x393939, 0x242424, 0x151515], glow: 0x5A5A5A,
            bookmark: [0xD5D5D5, 0x929292], edge: 0xFFFFFF,
            slot: 0x4B4B4B, dot: 0xFFFFFF
        )
    }
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func makeBitmap() -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    return (ctx, rep)
}

func gradient(
    _ ctx: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    start: CGPoint,
    end: CGPoint
) {
    let value = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(
        value, start: start, end: end,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func bookmarkPath() -> CGPath {
    let rect = CGRect(x: 310, y: 190, width: 404, height: 652)
    let radius: CGFloat = 78
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 18))
    path.addCurve(
        to: CGPoint(x: rect.midX, y: rect.maxY - 120),
        control1: CGPoint(x: rect.maxX - 72, y: rect.maxY - 12),
        control2: CGPoint(x: rect.midX + 76, y: rect.maxY - 120)
    )
    path.addCurve(
        to: CGPoint(x: rect.minX, y: rect.maxY - 18),
        control1: CGPoint(x: rect.midX - 76, y: rect.maxY - 120),
        control2: CGPoint(x: rect.minX + 72, y: rect.maxY - 12)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    path.closeSubpath()
    return path
}

func draw(_ appearance: Appearance) -> NSBitmapImageRep {
    let p = palette(appearance)
    let (ctx, rep) = makeBitmap()

    gradient(
        ctx, colors: p.background.map { color($0) }, locations: [0, 0.56, 1],
        start: CGPoint(x: 145, y: 70), end: CGPoint(x: 875, y: 970)
    )
    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(p.glow, alpha: 0.28), color(p.glow, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 300, y: 245), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 245), endRadius: 540,
        options: []
    )

    let bookmark = bookmarkPath()
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 28), blur: 46,
        color: color(0x100712, alpha: appearance == .tinted ? 0.28 : 0.42)
    )
    ctx.addPath(bookmark)
    ctx.clip()
    gradient(
        ctx, colors: p.bookmark.map { color($0) }, locations: [0, 1],
        start: CGPoint(x: 512, y: 175), end: CGPoint(x: 512, y: 850)
    )
    ctx.restoreGState()

    ctx.addPath(bookmark)
    ctx.setStrokeColor(color(p.edge, alpha: appearance == .tinted ? 0.42 : 0.30))
    ctx.setLineWidth(6)
    ctx.strokePath()

    let slot = CGPath(
        roundedRect: CGRect(x: 437, y: 374, width: 150, height: 54),
        cornerWidth: 27, cornerHeight: 27, transform: nil
    )
    ctx.addPath(slot)
    ctx.setFillColor(color(p.slot, alpha: 0.84))
    ctx.fillPath()

    let dot = CGPath(ellipseIn: CGRect(x: 484, y: 482, width: 56, height: 56), transform: nil)
    ctx.addPath(dot)
    ctx.setFillColor(color(p.dot, alpha: 0.94))
    ctx.fillPath()

    return rep
}

for appearance in Appearance.allCases {
    let image = draw(appearance)
    let source = image.cgImage!
    let bytesPerRow = Int(size) * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * Int(size))
    let opaque = CGContext(
        data: &pixels,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    opaque.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    let encoded = NSMutableData()
    let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, opaque.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    let data = encoded as Data
    let filename = "icon_\(appearance.rawValue).png"
    for destination in destinations {
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: destination + "/" + filename))
    }
    print("Generated \(filename)")
}

let macSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in macSizes {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", "\(pixels)", "\(pixels)",
        catalogDir + "/icon_light.png",
        "--out", catalogDir + "/" + filename
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "Failed to generate \(filename)")
}

print("Generated explicit macOS icon representations.")
print("Installed Editorial Bookmark icon assets.")
