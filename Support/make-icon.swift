// Build-time only: renders AppIcon.iconset. Not part of the app target.
//   swiftc Support/make-icon.swift -o /tmp/make-icon
//   /tmp/make-icon <out.iconset>
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-rect plate, inset like Apple's grid.
    let inset = size * 0.06
    let plate = rect.insetBy(dx: inset, dy: inset)
    let radius = plate.width * 0.2237
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.addPath(platePath)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [
                                CGColor(srgbRed: 0.161, green: 0.157, blue: 0.153, alpha: 1),
                                CGColor(srgbRed: 0.086, green: 0.086, blue: 0.086, alpha: 1),
                              ] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                          end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    cg.restoreGState()

    // A screen with a notch bitten out of its top edge, and the tiles you slot under it.
    let orange = CGColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    let screenW = size * 0.50, screenH = size * 0.44
    let screen = CGRect(x: (size - screenW) / 2, y: (size - screenH) / 2 + size * 0.02,
                        width: screenW, height: screenH)

    cg.saveGState()
    let body = CGMutablePath()
    let corner = screenH * 0.22
    let notchW = screenW * 0.42, notchH = screenH * 0.13, notchR = notchH * 0.55
    let top = screen.maxY, midX = screen.midX
    body.move(to: CGPoint(x: screen.minX + corner, y: top))
    body.addLine(to: CGPoint(x: midX - notchW / 2, y: top))
    body.addLine(to: CGPoint(x: midX - notchW / 2, y: top - notchH + notchR))
    body.addQuadCurve(to: CGPoint(x: midX - notchW / 2 + notchR, y: top - notchH),
                      control: CGPoint(x: midX - notchW / 2, y: top - notchH))
    body.addLine(to: CGPoint(x: midX + notchW / 2 - notchR, y: top - notchH))
    body.addQuadCurve(to: CGPoint(x: midX + notchW / 2, y: top - notchH + notchR),
                      control: CGPoint(x: midX + notchW / 2, y: top - notchH))
    body.addLine(to: CGPoint(x: midX + notchW / 2, y: top))
    body.addLine(to: CGPoint(x: screen.maxX - corner, y: top))
    body.addQuadCurve(to: CGPoint(x: screen.maxX, y: top - corner), control: CGPoint(x: screen.maxX, y: top))
    body.addLine(to: CGPoint(x: screen.maxX, y: screen.minY + corner))
    body.addQuadCurve(to: CGPoint(x: screen.maxX - corner, y: screen.minY), control: CGPoint(x: screen.maxX, y: screen.minY))
    body.addLine(to: CGPoint(x: screen.minX + corner, y: screen.minY))
    body.addQuadCurve(to: CGPoint(x: screen.minX, y: screen.minY + corner), control: CGPoint(x: screen.minX, y: screen.minY))
    body.addLine(to: CGPoint(x: screen.minX, y: top - corner))
    body.addQuadCurve(to: CGPoint(x: screen.minX + corner, y: top), control: CGPoint(x: screen.minX, y: top))
    body.closeSubpath()
    cg.addPath(body)
    cg.setStrokeColor(orange)
    cg.setLineWidth(max(1, size * 0.032))
    cg.strokePath()
    cg.restoreGState()

    // three tiles, the modules you drop in
    let tileH = screenH * 0.13
    let gap = screenH * 0.11
    let sideInset = screenW * 0.16
    let fullWidth = screenW - sideInset * 2
    // widest at the top, tapering down — a stack of modules sitting under the notch
    var y = screen.minY + screenH * 0.17
    for (index, width) in [fullWidth * 0.45, fullWidth * 0.72, fullWidth].enumerated() {
        let tile = CGRect(x: screen.minX + sideInset, y: y, width: width, height: tileH)
        cg.addPath(CGPath(roundedRect: tile, cornerWidth: tileH / 2, cornerHeight: tileH / 2, transform: nil))
        cg.setFillColor(orange.copy(alpha: 0.55 + 0.15 * Double(index)) ?? orange)
        cg.fillPath()
        y += tileH + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    guard let data = render(size: size) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("iconset → \(outDir)")
