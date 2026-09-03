#!/usr/bin/env swift
// Generates Rhapsode app-icon masters: light / dark / tinted, plus Icon Composer layers.
// Usage: swift scripts/generate-icon.swift
// Output: icon-variants/*.png (1024×1024)

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let outputDir = FileManager.default.currentDirectoryPath + "/icon-variants"

enum Variant {
    case light, dark, tinted
}

struct Palette {
    let bgTop: UInt32
    let bgBottom: UInt32
    let page: UInt32
    let gutter: UInt32
    let wave: UInt32
}

func palette(for variant: Variant) -> Palette {
    switch variant {
    case .light:
        // Ink & Mint — light: mint field, cream pages, deepened mint wave.
        return Palette(bgTop: 0xC5E8D6, bgBottom: 0x7FBF9E, page: 0xF7F4EC, gutter: 0xDDD6C8, wave: 0x0C7A5A)
    case .dark:
        return Palette(bgTop: 0x14201B, bgBottom: 0x07110D, page: 0xEAF2EE, gutter: 0xC4D2CB, wave: 0x35D6A4)
    case .tinted:
        // Strict grayscale — iOS overlays the user's Home Screen tint.
        return Palette(bgTop: 0x2C2C2C, bgBottom: 0x1A1A1A, page: 0x8E8E8E, gutter: 0x6A6A6A, wave: 0xFFFFFF)
    }
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let colorSpace = CGColorSpaceCreateDeviceRGB()

func makeContext() -> (CGContext, NSBitmapImageRep) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ), let gc = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not allocate a 1024×1024 bitmap context")
    }
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    return (ctx, rep)
}

func drawGradientBackground(_ ctx: CGContext, from: UInt32, to: UInt32) {
    let colors = [rgb(from), rgb(to)] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

/// Open book: two front-facing pages meeting at a center gutter. No tilt, no lighting.
func addOpenBookPath() -> CGPath {
    let pageW = size * 0.30
    let pageH = size * 0.50
    let cx = size * 0.50
    let cy = size * 0.52
    let gap = size * 0.018
    let corner = size * 0.055

    let path = CGMutablePath()
    let left = CGRect(x: cx - gap / 2 - pageW, y: cy - pageH / 2, width: pageW, height: pageH)
    let right = CGRect(x: cx + gap / 2, y: cy - pageH / 2, width: pageW, height: pageH)
    path.addRoundedRect(in: left, cornerWidth: corner, cornerHeight: corner)
    path.addRoundedRect(in: right, cornerWidth: corner, cornerHeight: corner)
    return path
}

func addGutterPath() -> CGPath {
    let cx = size * 0.50
    let cy = size * 0.52
    let pageH = size * 0.50
    let gutterW = size * 0.034
    let rect = CGRect(x: cx - gutterW / 2, y: cy - pageH / 2 + size * 0.02, width: gutterW, height: pageH - size * 0.04)
    return CGPath(roundedRect: rect, cornerWidth: gutterW / 2, cornerHeight: gutterW / 2, transform: nil)
}

func addWaveformPath() -> CGPath {
    let center = CGPoint(x: size * 0.50, y: size * 0.52)
    let barCount = 7
    let barWidth = size * 0.038
    let maxHeight = size * 0.28
    let spacing = barWidth * 1.55
    let totalWidth = CGFloat(barCount) * spacing - (spacing - barWidth)
    let startX = center.x - totalWidth / 2
    // Speech-like cadence, not a perfect pyramid — still readable at 60px.
    let heights: [CGFloat] = [0.32, 0.62, 0.95, 0.48, 1.00, 0.70, 0.38]

    let path = CGMutablePath()
    for i in 0..<barCount {
        let h = maxHeight * heights[i]
        let x = startX + CGFloat(i) * spacing
        let rect = CGRect(x: x, y: center.y - h / 2, width: barWidth, height: h)
        path.addRoundedRect(in: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
    }
    return path
}

func fill(_ ctx: CGContext, path: CGPath, hex: UInt32) {
    ctx.addPath(path)
    ctx.setFillColor(rgb(hex))
    ctx.fillPath()
}

func save(_ rep: NSBitmapImageRep, name: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(name)\n", stderr)
        return
    }
    let url = URL(fileURLWithPath: "\(outputDir)/\(name).png")
    do {
        try png.write(to: url)
        print("Saved: \(url.path)")
    } catch {
        fputs("Failed to write \(name): \(error)\n", stderr)
    }
}

func generateComposite(_ variant: Variant) -> NSBitmapImageRep {
    let colors = palette(for: variant)
    let (ctx, rep) = makeContext()
    drawGradientBackground(ctx, from: colors.bgTop, to: colors.bgBottom)
    fill(ctx, path: addOpenBookPath(), hex: colors.page)
    fill(ctx, path: addGutterPath(), hex: colors.gutter)
    fill(ctx, path: addWaveformPath(), hex: colors.wave)
    return rep
}

func generateLayerBackground(_ variant: Variant) -> NSBitmapImageRep {
    let colors = palette(for: variant)
    let (ctx, rep) = makeContext()
    drawGradientBackground(ctx, from: colors.bgTop, to: colors.bgBottom)
    return rep
}

func generateLayerTransparent(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let (ctx, rep) = makeContext()
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    draw(ctx)
    return rep
}

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
print("Generating Rhapsode icon variants at \(Int(size))×\(Int(size))...")

save(generateComposite(.light), name: "icon_light")
save(generateComposite(.dark), name: "icon_dark")
save(generateComposite(.tinted), name: "icon_tinted")

// Icon Composer source layers (effect-free). Prefix = Z-order.
save(generateLayerBackground(.light), name: "0-background-light")
save(generateLayerBackground(.dark), name: "0-background-dark")
save(generateLayerTransparent { fill($0, path: addOpenBookPath(), hex: palette(for: .dark).page) }, name: "1-book-pages")
save(generateLayerTransparent { fill($0, path: addGutterPath(), hex: palette(for: .dark).gutter) }, name: "2-gutter")
save(generateLayerTransparent { fill($0, path: addWaveformPath(), hex: palette(for: .dark).wave) }, name: "3-waveform")

print("Done.")
