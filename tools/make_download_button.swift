//
//  make_download_button.swift
//  Sesame (tools)
//
//  Renders the README's download button. Kept in the repo so the asset can be regenerated rather
//  than being an orphaned binary nobody can reproduce.
//
//    swiftc -O -o /tmp/make_download_button tools/make_download_button.swift
//    /tmp/make_download_button && cp /tmp/download-for-mac.png .github/assets/
//

import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Apple-style pill button: flat fill, generous padding, semibold system text, no gradient.
func render(scale: CGFloat, width baseW: CGFloat, height baseH: CGFloat, to url: URL) {
    let w = Int(baseW * scale), h = Int(baseH * scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // top-left origin
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let s = scale
    let rect = CGRect(x: 0, y: 0, width: baseW * s, height: baseH * s)

    // Apple's system blue for call-to-action buttons.
    ctx.setFillColor(CGColor(red: 0x00/255, green: 0x71/255, blue: 0xE3/255, alpha: 1))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
    ctx.fillPath()

    let fontSize = 21 * s
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let title = "Download for Mac"
    let attributed = NSAttributedString(string: title, attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: 0.2 * s,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)

    // Download glyph: a stroked downward arrow over a tray, drawn rather than set in a font so it
    // does not depend on any glyph being present on the renderer's machine.
    let glyphW = 17 * s
    let gap = 11 * s
    let totalW = glyphW + gap + CGFloat(textWidth)
    let originX = (rect.width - totalW) / 2
    let midY = rect.height / 2

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(2.1 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let gx = originX + glyphW / 2
    // Shaft.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: gx, y: midY - 9 * s))
    ctx.addLine(to: CGPoint(x: gx, y: midY + 3.0 * s))
    ctx.strokePath()
    // Arrow head.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: gx - 5.2 * s, y: midY - 2.2 * s))
    ctx.addLine(to: CGPoint(x: gx, y: midY + 3.2 * s))
    ctx.addLine(to: CGPoint(x: gx + 5.2 * s, y: midY - 2.2 * s))
    ctx.strokePath()
    // Tray.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: gx - 7.5 * s, y: midY + 5.4 * s))
    ctx.addLine(to: CGPoint(x: gx - 7.5 * s, y: midY + 9 * s))
    ctx.addLine(to: CGPoint(x: gx + 7.5 * s, y: midY + 9 * s))
    ctx.addLine(to: CGPoint(x: gx + 7.5 * s, y: midY + 5.4 * s))
    ctx.strokePath()

    // Baseline centring uses the font's own metrics, not the glyph bounds, so the text sits on the
    // optical centre rather than bouncing with ascenders and descenders.
    ctx.textMatrix = .identity
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.height)
    ctx.scaleBy(x: 1, y: -1)
    let baseline = rect.height / 2 - (font.ascender + font.descender) / 2
    ctx.textPosition = CGPoint(x: originX + glyphW + gap, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent) at \(w)x\(h)")
}

render(scale: 3, width: 260, height: 56, to: URL(fileURLWithPath: "/tmp/btn/download-for-mac.png"))
render(scale: 1, width: 260, height: 56, to: URL(fileURLWithPath: "/tmp/btn/preview.png"))
