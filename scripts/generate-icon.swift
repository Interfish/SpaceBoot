#!/usr/bin/env swift
//
// generate-icon.swift
// Generates SpaceBoot's AppIcon.icns, README icon PNG (512x512), and optional visual preview sheet
// from Resources/AppIconSource.png + matching CoreGraphics vector Menu Bar glyph.
//
// Usage:
//   swift scripts/generate-icon.swift [--preview /tmp/spaceboot-preview.png]
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Authentic macOS Squircle & Shared Geometry

/// Continuous-curvature rounded rectangle matching macOS icon squircle geometry
/// (clean straight sides with smooth superellipse corner transitions).
func createSuperellipseRect(in rect: CGRect, cornerRadius r: CGFloat) -> CGPath {
    let maxR = min(rect.width, rect.height) / 2
    let radius = min(r, maxR)
    let ext = min(radius * 1.24, maxR)
    let handle = ext * 0.44

    let minX = rect.minX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY

    let path = CGMutablePath()
    path.move(to: CGPoint(x: minX + ext, y: maxY))

    path.addLine(to: CGPoint(x: maxX - ext, y: maxY))
    path.addCurve(
        to: CGPoint(x: maxX, y: maxY - ext),
        control1: CGPoint(x: maxX - handle, y: maxY),
        control2: CGPoint(x: maxX, y: maxY - handle)
    )

    path.addLine(to: CGPoint(x: maxX, y: minY + ext))
    path.addCurve(
        to: CGPoint(x: maxX - ext, y: minY),
        control1: CGPoint(x: maxX, y: minY + handle),
        control2: CGPoint(x: maxX - handle, y: minY)
    )

    path.addLine(to: CGPoint(x: minX + ext, y: minY))
    path.addCurve(
        to: CGPoint(x: minX, y: minY + ext),
        control1: CGPoint(x: minX + handle, y: minY),
        control2: CGPoint(x: minX, y: minY + handle)
    )

    path.addLine(to: CGPoint(x: minX, y: maxY - ext))
    path.addCurve(
        to: CGPoint(x: minX + ext, y: maxY),
        control1: CGPoint(x: minX, y: maxY - handle),
        control2: CGPoint(x: minX + handle, y: maxY)
    )

    path.closeSubpath()
    return path
}

/// Rounded slanted parallelogram matching SpaceBoot's C1 layered Space planes.
func createSlantedPlanePath(
    origin: CGPoint,
    width: CGFloat,
    height: CGFloat,
    slant: CGFloat,
    cornerRadius: CGFloat
) -> CGPath {
    let p0 = CGPoint(x: origin.x, y: origin.y)
    let p1 = CGPoint(x: origin.x + width, y: origin.y)
    let p2 = CGPoint(x: origin.x + width + slant, y: origin.y + height)
    let p3 = CGPoint(x: origin.x + slant, y: origin.y + height)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: (p0.x + p1.x) * 0.5, y: p0.y))
    path.addArc(tangent1End: p1, tangent2End: p2, radius: cornerRadius)
    path.addArc(tangent1End: p2, tangent2End: p3, radius: cornerRadius)
    path.addArc(tangent1End: p3, tangent2End: p0, radius: cornerRadius)
    path.addArc(tangent1End: p0, tangent2End: p1, radius: cornerRadius)
    path.closeSubpath()
    return path
}

// MARK: - App Icon Renderer (1024x1024 Canonical Space)

func loadSourceImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(
            domain: "SpaceBootIcon",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Failed to load source artwork at \(url.path)"]
        )
    }
    return image
}

func drawAppIcon(in ctx: CGContext, pixelSize: Int, sourceImage: CGImage) {
    let size = CGFloat(pixelSize)
    let scale = size / 1024.0
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    ctx.saveGState()
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)

    // 1. Standard macOS HIG tile bounds (824x824 centered in 1024x1024 canvas)
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = createSuperellipseRect(in: tileRect, cornerRadius: 184)

    // 2. Soft ambient elevation shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -16 * scale),
        blur: 26 * scale,
        color: CGColor(colorSpace: colorSpace, components: [0.01, 0.02, 0.06, 0.36])!
    )
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.06, 0.08, 0.14, 1.0])!)
    ctx.fillPath()
    ctx.restoreGState()

    // 3. Clip full-bleed C1 master artwork to the squircle tile
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.draw(sourceImage, in: tileRect)
    ctx.restoreGState()

    // 4. Outer squircle anodized-glass rim (crisp definition against light and dark wallpapers)
    ctx.saveGState()
    let rimRect = tileRect.insetBy(dx: 1.5, dy: 1.5)
    let rimPath = createSuperellipseRect(in: rimRect, cornerRadius: 182.5)
    ctx.addPath(rimPath)
    ctx.setLineWidth(3.0)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.28])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.08])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.04])!
    ] as CFArray
    if let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: 512, y: tileRect.maxY),
            end: CGPoint(x: 512, y: tileRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Menu Bar Template Icon Renderer (parity preview with Sources/StatusBarIcon.swift)

func drawMenuBarGlyph(in ctx: CGContext, rect: CGRect, tint: CGColor, activePhase: Int? = nil) {
    let sx = rect.width / 18.0
    let sy = rect.height / 18.0
    ctx.saveGState()
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: sx, y: sy)

    let planeWidth: CGFloat = 8.2
    let planeHeight: CGFloat = 6.8
    let planeSlant: CGFloat = 4.3
    let cornerRadius: CGFloat = 1.2
    let separatorStrokeWidth: CGFloat = 2.1

    let origins = [
        CGPoint(x: 4.35, y: 2.30), // Back / bottom-right plane
        CGPoint(x: 2.75, y: 5.60), // Middle plane
        CGPoint(x: 1.15, y: 8.90)  // Front / top-left plane
    ]
    let idleAlphas: [CGFloat] = [0.40, 0.68, 1.0]
    let alphas: [CGFloat] = activePhase.map { phase in
        (0..<3).map { $0 == phase ? 1.0 : 0.34 }
    } ?? idleAlphas

    // Transparency layer keeps .clear gap punch-outs isolated to the glyph itself.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    for index in 0..<origins.count {
        let planePath = createSlantedPlanePath(
            origin: origins[index],
            width: planeWidth,
            height: planeHeight,
            slant: planeSlant,
            cornerRadius: cornerRadius
        )

        if index > 0 {
            ctx.setBlendMode(.clear)
            ctx.addPath(planePath)
            ctx.fillPath()
            ctx.setLineWidth(separatorStrokeWidth)
            ctx.setLineJoin(.round)
            ctx.addPath(planePath)
            ctx.strokePath()
        }

        ctx.setBlendMode(.normal)
        ctx.setFillColor(tint.copy(alpha: alphas[index]) ?? tint)
        ctx.addPath(planePath)
        ctx.fillPath()
    }

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - PNG & ICNS Output

func renderPNG(size: Int, to url: URL, draw: (CGContext) -> Void) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "SpaceBootIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    draw(ctx)

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "SpaceBootIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SpaceBootIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: url)
}

func renderPreviewSheet(to url: URL, sourceImage: CGImage) throws {
    let width = 1120
    let height = 720
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.93, 0.94, 0.96, 1.0])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.11, 0.12, 0.15, 1.0])!)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))

    func drawIconAt(x: CGFloat, y: CGFloat, size: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        drawAppIcon(in: ctx, pixelSize: Int(size), sourceImage: sourceImage)
        ctx.restoreGState()
    }

    drawIconAt(x: 100, y: 270, size: 360)
    drawIconAt(x: 660, y: 270, size: 360)

    drawIconAt(x: 70, y: 120, size: 128)
    drawIconAt(x: 230, y: 152, size: 64)
    drawIconAt(x: 330, y: 168, size: 32)

    drawIconAt(x: 630, y: 120, size: 128)
    drawIconAt(x: 790, y: 152, size: 64)
    drawIconAt(x: 890, y: 168, size: 32)

    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.88])!)
    ctx.fill(CGRect(x: 40, y: 26, width: 480, height: 64))
    let darkTint = CGColor(colorSpace: colorSpace, components: [0.08, 0.08, 0.10, 1.0])!
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 70, y: 40, width: 36, height: 36), tint: darkTint)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 130, y: 31, width: 54, height: 54), tint: darkTint)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 230, y: 40, width: 36, height: 36), tint: darkTint, activePhase: 0)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 280, y: 40, width: 36, height: 36), tint: darkTint, activePhase: 1)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 330, y: 40, width: 36, height: 36), tint: darkTint, activePhase: 2)

    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.18, 0.19, 0.23, 0.95])!)
    ctx.fill(CGRect(x: 600, y: 26, width: 480, height: 64))
    let lightTint = CGColor(colorSpace: colorSpace, components: [0.96, 0.97, 1.0, 1.0])!
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 630, y: 40, width: 36, height: 36), tint: lightTint)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 690, y: 31, width: 54, height: 54), tint: lightTint)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 790, y: 40, width: 36, height: 36), tint: lightTint, activePhase: 0)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 840, y: 40, width: 36, height: 36), tint: lightTint, activePhase: 1)
    drawMenuBarGlyph(in: ctx, rect: CGRect(x: 890, y: 40, width: 36, height: 36), tint: lightTint, activePhase: 2)

    guard let cgImage = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: url)
    }
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourceImageURL = repoRoot.appendingPathComponent("Resources/AppIconSource.png")
let sourceImage = try loadSourceImage(at: sourceImageURL)

var previewPath: String?
if let idx = CommandLine.arguments.firstIndex(of: "--preview"), idx + 1 < CommandLine.arguments.count {
    previewPath = CommandLine.arguments[idx + 1]
}

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("spaceboot-icon-\(UUID().uuidString)")
let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

let entries: [(name: String, pixels: Int)] = [
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

for entry in entries {
    let dest = iconsetDir.appendingPathComponent(entry.name)
    try renderPNG(size: entry.pixels, to: dest) { ctx in
        drawAppIcon(in: ctx, pixelSize: entry.pixels, sourceImage: sourceImage)
    }
}

let icnsOutput = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: icnsOutput.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsOutput.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("error: iconutil failed with status \(iconutil.terminationStatus)\n", stderr)
    exit(1)
}

let readmeIconOutput = repoRoot.appendingPathComponent("docs/icon.png")
try renderPNG(size: 512, to: readmeIconOutput) { ctx in
    drawAppIcon(in: ctx, pixelSize: 512, sourceImage: sourceImage)
}

if let previewPath {
    try renderPreviewSheet(to: URL(fileURLWithPath: previewPath), sourceImage: sourceImage)
    print("Wrote preview: \(previewPath)")
}

print("Generated: \(icnsOutput.path)")
print("Generated: \(readmeIconOutput.path)")
