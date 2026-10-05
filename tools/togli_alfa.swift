import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Riscrive i PNG passati come argomento senza canale alfa (sfondo opaco).
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("ERRORE lettura \(path)"); continue }
    let w = img.width, h = img.height
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { print("ERRORE ctx"); continue }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { print("ERRORE out"); continue }
    CGImageDestinationAddImage(dst, out, nil)
    print(CGImageDestinationFinalize(dst) ? "ok \(path)" : "ERRORE scrittura \(path)")
}
