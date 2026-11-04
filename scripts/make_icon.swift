import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// iPod Classic style icon: dark body, LCD with menu, click wheel below.
let size = 1024
let W = CGFloat(size)

let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Background body
ctx.setFillColor(CGColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))

let colors = [CGColor(red: 0.09, green: 0.09, blue: 0.095, alpha: 1), CGColor(red: 0.015, green: 0.015, blue: 0.02, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawRadialGradient(grad, startCenter: CGPoint(x: W / 2, y: W * 0.7), startRadius: 0, endCenter: CGPoint(x: W / 2, y: W * 0.5), endRadius: W * 0.8, options: [])

// ---- Screen (4:3), centered horizontally, top-anchored
let screenW = W * 0.60
let screenH = screenW * 0.75
let screenX = (W - screenW) / 2
let screenTop = W * 0.86
let screenY = screenTop - screenH  // CG y is bottom-up

ctx.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1))
ctx.fill(CGRect(x: screenX - 8, y: screenY - 8, width: screenW + 16, height: screenH + 16))
ctx.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.945, alpha: 1))
ctx.fill(CGRect(x: screenX, y: screenY, width: screenW, height: screenH))

// Title bar
let barH = screenH * 0.13
ctx.setFillColor(CGColor(red: 0.77, green: 0.775, blue: 0.785, alpha: 1))
ctx.fill(CGRect(x: screenX, y: screenTop - barH, width: screenW, height: barH))

// Menu rows: selected blue row + text slivers below it
let rowH = screenH * 0.13
let rowInset: CGFloat = 10

// selected row (2nd from top)
let selIndex: CGFloat = 1
let selTopInScreen = barH + selIndex * rowH * 1.35
let selRect = CGRect(x: screenX + rowInset, y: screenTop - selTopInScreen - rowH, width: screenW - rowInset * 2, height: rowH)
let selColors = [CGColor(red: 0.475, green: 0.655, blue: 0.898, alpha: 1), CGColor(red: 0.204, green: 0.4, blue: 0.784, alpha: 1)] as CFArray
let selGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: selColors, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: selRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.clip()
ctx.drawLinearGradient(selGrad, start: CGPoint(x: selRect.midX, y: selRect.maxY), end: CGPoint(x: selRect.midX, y: selRect.minY), options: [])
ctx.restoreGState()

// Text slivers on the unselected rows
ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
ctx.setAlpha(0.85)
let textSlots: [(CGFloat, CGFloat)] = [(0, 0.42), (2, 0.36), (3, 0.30), (4, 0.44), (5, 0.32)]
for (row, widthFrac) in textSlots {
    let rowTopInScreen = barH + row * rowH * 1.35 + rowH * 0.32
    if screenTop - rowTopInScreen > screenY + 4 {
        ctx.fill(CGRect(x: screenX + rowInset + 8, y: screenTop - rowTopInScreen - 10, width: (screenW - rowInset * 2) * widthFrac, height: 10))
    }
}
ctx.setAlpha(1)

// ---- Click wheel: perfect circle centered in the lower body
let wheelD = W * 0.56
let wheelRect = CGRect(x: (W - wheelD) / 2, y: W * 0.32 - wheelD / 2, width: wheelD, height: wheelD)
let wheelCenter = CGPoint(x: wheelRect.midX, y: wheelRect.midY)

let wheelColors = [CGColor(red: 0.20, green: 0.20, blue: 0.205, alpha: 1), CGColor(red: 0.13, green: 0.13, blue: 0.135, alpha: 1)] as CFArray
let wheelGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: wheelColors, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(CGPath(ellipseIn: wheelRect, transform: nil))
ctx.clip()
ctx.drawRadialGradient(wheelGrad, startCenter: wheelCenter, startRadius: 0, endCenter: wheelCenter, endRadius: wheelD / 2, options: [])
ctx.restoreGState()
ctx.setStrokeColor(CGColor(red: 0.30, green: 0.30, blue: 0.31, alpha: 1))
ctx.setLineWidth(3)
ctx.strokeEllipse(in: wheelRect)

// Center button
let centerD = wheelD * 0.365
ctx.setFillColor(CGColor(red: 0.065, green: 0.065, blue: 0.07, alpha: 1))
ctx.fillEllipse(in: CGRect(x: wheelCenter.x - centerD / 2, y: wheelCenter.y - centerD / 2, width: centerD, height: centerD))

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("icon written to \(url.path)")
