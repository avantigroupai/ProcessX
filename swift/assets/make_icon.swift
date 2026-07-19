// Draws the ProcessX app icon at every macOS iconset size with CoreGraphics
// (pure vector → crisp from 16px to 1024px) and writes them into an .iconset
// folder. Run:  swift assets/make_icon.swift  (see assets/build_icon.sh)
//
// Mark: the app's brand glyph — an ECG / heartbeat waveform — in white, the
// "pulse of your Mac", on the Liquid Glass Apple-blue squircle.

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

func drawIcon(_ S: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext

    // Work in top-left coordinates (y grows downward), like the layout maths.
    cg.translateBy(x: 0, y: S); cg.scaleBy(x: 1, y: -1)
    cg.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // Rounded-rect ("squircle") tile with the standard macOS proportions and a
    // little margin for the drop shadow.
    let margin = 0.092 * S
    let side = S - 2 * margin
    let rect = CGRect(x: margin, y: margin, width: side, height: side)
    let radius = 0.2237 * side
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft contact shadow beneath the tile.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -0.018 * S), blur: 0.05 * S,
                 color: srgb(0, 0, 0, 0.30))
    cg.addPath(tile); cg.setFillColor(srgb(0.02, 0.10, 0.28)); cg.fillPath()
    cg.restoreGState()

    // Blue gradient fill, clipped to the tile.
    cg.saveGState()
    cg.addPath(tile); cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [srgb(0.28, 0.62, 1.00), srgb(0.09, 0.42, 0.97), srgb(0.03, 0.28, 0.86)] as CFArray,
                          locations: [0, 0.55, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY),
                          end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])

    // Liquid-glass top sheen: a soft white glow fading down from the top.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [srgb(1, 1, 1, 0.28), srgb(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    cg.drawRadialGradient(sheen,
                          startCenter: CGPoint(x: rect.midX, y: rect.minY + side * 0.06), startRadius: 0,
                          endCenter: CGPoint(x: rect.midX, y: rect.minY + side * 0.10), endRadius: side * 0.72,
                          options: [])
    cg.restoreGState()

    // Inner rim highlight for the glass edge.
    cg.saveGState()
    let rim = CGPath(roundedRect: rect.insetBy(dx: side * 0.012, dy: side * 0.012),
                     cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(rim); cg.setStrokeColor(srgb(1, 1, 1, 0.22)); cg.setLineWidth(max(1, side * 0.006)); cg.strokePath()
    cg.restoreGState()

    // ECG / heartbeat waveform — the brand mark. Points in fractions of S.
    let pts: [(CGFloat, CGFloat)] = [
        (0.150, 0.520), (0.300, 0.520), (0.352, 0.435), (0.410, 0.520),
        (0.452, 0.582), (0.512, 0.300), (0.566, 0.690), (0.620, 0.520),
        (0.700, 0.520), (0.752, 0.470), (0.804, 0.520), (0.850, 0.520),
    ]
    let line = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let cp = CGPoint(x: p.0 * S, y: p.1 * S)
        if i == 0 { line.move(to: cp) } else { line.addLine(to: cp) }
    }
    cg.saveGState()
    cg.setLineCap(.round); cg.setLineJoin(.round); cg.setLineWidth(side * 0.062)
    cg.setShadow(offset: CGSize(width: 0, height: -0.006 * S), blur: 0.02 * S, color: srgb(0.02, 0.15, 0.45, 0.55))
    cg.addPath(line); cg.setStrokeColor(srgb(1, 1, 1, 1)); cg.strokePath()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (pixel size, iconset filename)
let variants: [(CGFloat, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in variants {
    let data = drawIcon(size)
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(variants.count) PNGs to \(outDir)")
