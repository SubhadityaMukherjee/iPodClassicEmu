import Foundation
import CoreGraphics
import ImageIO

/// Rounds the corners of the given PNGs in place (transparent corners).
/// Usage: swift round_corners.swift <radiusPx> <file.png> [more.png ...]
let args = CommandLine.arguments
guard args.count >= 3, let radius = Double(args[1]), radius > 0 else {
    print("usage: round_corners.swift <radiusPx> <file.png> ...")
    exit(1)
}

for path in args.dropFirst() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("skip (unreadable): \(path)")
        continue
    }
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(clip)
    ctx.clip()
    ctx.draw(image, in: rect)
    guard let out = ctx.makeImage() else {
        print("skip (context): \(path)")
        continue
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    guard CGImageDestinationFinalize(dest) else {
        print("skip (write): \(path)")
        continue
    }
    print("rounded: \(path)")
}
