// Build-time only: renders AppIcon.iconset from the Claude mark.
// Not part of the app target.
//   swiftc Support/make-icon.swift Sources/ClaudeNotch/ClaudeMark.swift -o /tmp/make-icon
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

    // Mark, centred, in Claude orange.
    let markSize = size * 0.54
    let markRect = CGRect(x: (size - markSize) / 2, y: (size - markSize) / 2, width: markSize, height: markSize)
    var path = ClaudeMark().path(in: markRect).cgPath
    // Flip: SVG is y-down, the bitmap context is y-up.
    var flip = CGAffineTransform(translationX: 0, y: size).scaledBy(x: 1, y: -1)
    path = path.copy(using: &flip) ?? path

    cg.saveGState()
    cg.addPath(path)
    cg.setFillColor(CGColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

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
