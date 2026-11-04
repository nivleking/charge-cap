// Draws the ChargeCap app icon as a 1024x1024 PNG with CoreGraphics only (no Xcode).
// Usage: swift scripts/make-icon.swift [Resources/AppIcon-1024.png]
// make-app.sh turns that PNG into AppIcon.icns with sips + iconutil.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Draw in top-left coordinates (y grows downwards), like most design tools.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}

/// Shadows ignore the flipped transform, so a positive `drop` moves them down on screen.
func fill(_ path: CGPath, _ color: CGColor, drop: CGFloat = 0, blur: CGFloat = 0, shadow: CGColor? = nil) {
    ctx.saveGState()
    if let shadow { ctx.setShadow(offset: CGSize(width: 0, height: -drop), blur: blur, color: shadow) }
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

func fillGradient(_ path: CGPath, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
    ctx.restoreGState()
}

// Tile: 824 px rounded square on Apple icon grid.
let tile = rounded(100, 100, 824, 824, 185)

fill(tile, rgb(30, 150, 90), drop: 12, blur: 36, shadow: rgb(0, 0, 0, 0.43))
fillGradient(tile, top: rgb(70, 205, 120), bottom: rgb(20, 130, 110))

// A battery: white shell, filled to 80%, with a notch marking the limit.
fill(rounded(228, 340, 540, 344, 78), rgb(255, 255, 255), drop: 8, blur: 20, shadow: rgb(0, 60, 30, 0.4))
fill(rounded(764, 458, 52, 108, 24), rgb(255, 255, 255))
fill(rounded(262, 374, 472, 276, 46), rgb(15, 105, 80, 0.92))                          // inside
fill(rounded(262, 374, 472 * 0.8, 276, 46), rgb(150, 245, 185))                         // charge up to the limit
// The limit marker at 80%, reaching above and below the battery.
let markerX = 262 + 472 * 0.8
fill(rounded(markerX - 11, 292, 22, 440, 11), rgb(255, 224, 90), drop: 4, blur: 12, shadow: rgb(60, 40, 0, 0.5))
fill(CGPath(ellipseIn: CGRect(x: markerX - 30, y: 262, width: 60, height: 60), transform: nil), rgb(255, 224, 90))

let url = URL(fileURLWithPath: out)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(out)") }
print("Wrote \(out)")

