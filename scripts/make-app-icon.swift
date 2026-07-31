// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.
//
// Draws the app icon and writes an .iconset for `iconutil`. Run via scripts/make-app-icon.sh.
//
// The mark follows DESIGN.md: the app's blue as the tile, a white document sheet, and the
// document-red badge used elsewhere for PDF iconography (§2's `documentBadge` token), so the
// icon reads as part of the app rather than bolted on.

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func draw(size S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS icons sit on a rounded square inset from the canvas edge.
    let inset = S * 0.08
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = rect.width * 0.2237                       // Apple's continuous-corner ratio
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Blue tile with a top-to-bottom gradient, matching the primary button's treatment.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let top = CGColor(red: 0.16, green: 0.55, blue: 1.00, alpha: 1)      // #2A8CFF
    let bottom = CGColor(red: 0.00, green: 0.38, blue: 0.85, alpha: 1)   // #0061D9
    let gradient = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // White sheet, portrait, with a folded top-right corner.
    let sheetW = rect.width * 0.46
    let sheetH = sheetW * 1.29
    let sheet = CGRect(x: rect.midX - sheetW / 2,
                       y: rect.midY - sheetH / 2 + rect.height * 0.035,
                       width: sheetW, height: sheetH)
    let fold = sheetW * 0.30

    let body = CGMutablePath()
    body.move(to: CGPoint(x: sheet.minX, y: sheet.minY))
    body.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY))
    body.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    body.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    body.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY))
    body.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    // The fold, slightly darker so the corner reads.
    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    foldPath.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
    foldPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    foldPath.closeSubpath()
    ctx.setFillColor(CGColor(red: 0.82, green: 0.87, blue: 0.94, alpha: 1))
    ctx.addPath(foldPath)
    ctx.fillPath()

    // Compression: two solid triangles pressing toward each other across a gap — the
    // squeeze the app performs. Drawn as separate wedges so they never overlap into a star.
    let cx = sheet.midX
    let cy = sheet.midY - sheet.height * 0.01
    let arrowW = sheetW * 0.40
    let arrowH = sheetH * 0.10
    let gap = sheetH * 0.030
    ctx.setFillColor(CGColor(red: 0.00, green: 0.44, blue: 0.89, alpha: 1))
    for direction in [1.0, -1.0] as [CGFloat] {
        let apexY = cy + direction * gap                    // inner point, next to the gap
        let baseY = apexY + direction * arrowH              // outer edge
        let wedge = CGMutablePath()
        wedge.move(to: CGPoint(x: cx - arrowW / 2, y: baseY))
        wedge.addLine(to: CGPoint(x: cx + arrowW / 2, y: baseY))
        wedge.addLine(to: CGPoint(x: cx, y: apexY))
        wedge.closeSubpath()
        ctx.addPath(wedge)
        ctx.fillPath()
    }

    // Red PDF badge, the same document-red used for file rows in the app.
    let badgeH = sheetH * 0.20
    let badgeW = sheetW * 0.74
    let badge = CGRect(x: sheet.midX - badgeW / 2,
                       y: sheet.minY - badgeH * 0.34,
                       width: badgeW, height: badgeH)
    let badgePath = CGPath(roundedRect: badge, cornerWidth: badgeH * 0.28,
                           cornerHeight: badgeH * 0.28, transform: nil)
    ctx.setFillColor(CGColor(red: 0.90, green: 0.19, blue: 0.15, alpha: 1))
    ctx.addPath(badgePath)
    ctx.fillPath()

    // "PDF" wordmark, drawn only where it stays legible.
    if S >= 128 {
        let text = "PDF" as NSString
        let font = NSFont.systemFont(ofSize: badgeH * 0.56, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: badgeH * 0.03,
        ]
        let bounds = text.size(withAttributes: attributes)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: CGPoint(x: badge.midX - bounds.width / 2,
                              y: badge.midY - bounds.height / 2),
                  withAttributes: attributes)
        NSGraphicsContext.current = previous
    }

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = outputDirectory.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("cannot write \(name)") }
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

// The set macOS expects, each at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    write(draw(size: CGFloat(base)), "icon_\(base)x\(base).png")
    write(draw(size: CGFloat(base * 2)), "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset to \(outputDirectory.path)")
