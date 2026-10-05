#!/usr/bin/env swift
// Genera l'icona di Salute Libera (1024×1024) con CoreGraphics.
// Uso:  swift tools/genera_icona.swift <cartella-di-uscita>
// Produce AppIcon.png (chiara), AppIcon-Dark.png (scura) e AppIcon-Tinted.png (tinta).
//
// Motivo: un cuore pieno attraversato da una freccia scavata che sale e ne apre
// l'incavo: i tuoi dati di salute escono liberi, verso dove decidi tu.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Il cuore pieno.
func heartPath() -> CGPath {
    let p = CGMutablePath()
    // Coordinate con origine in alto a sinistra (il contesto viene capovolto).
    let cleft = CGPoint(x: 512, y: 330)
    p.move(to: cleft)
    p.addCurve(to: CGPoint(x: 196, y: 420),
               control1: CGPoint(x: 452, y: 196), control2: CGPoint(x: 224, y: 190))
    p.addCurve(to: CGPoint(x: 512, y: 880),
               control1: CGPoint(x: 172, y: 600), control2: CGPoint(x: 392, y: 752))
    p.addCurve(to: CGPoint(x: 828, y: 420),
               control1: CGPoint(x: 632, y: 752), control2: CGPoint(x: 852, y: 600))
    p.addCurve(to: cleft,
               control1: CGPoint(x: 800, y: 190), control2: CGPoint(x: 572, y: 196))
    p.closeSubpath()
    return p
}

/// La freccia scavata nel cuore: sale e sfonda l'incavo.
func arrowPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 664))
    p.addLine(to: CGPoint(x: 512, y: 250))
    p.move(to: CGPoint(x: 402, y: 380))
    p.addLine(to: CGPoint(x: 512, y: 266))
    p.addLine(to: CGPoint(x: 622, y: 380))
    return p
}

enum Variant { case light, dark, tinted }

func render(_ v: Variant) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    let all: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    // Sfondo
    switch v {
    case .light:
        let g = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFF7A59), rgb(0xF2366F), rgb(0x9B2FD9), rgb(0x4A2BC4)] as CFArray,
                           locations: [0, 0.38, 0.78, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 160, y: 0), end: CGPoint(x: 864, y: S), options: all)
        let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 250, y: 150), startRadius: 0,
                               endCenter: CGPoint(x: 250, y: 150), endRadius: 640, options: [])
    case .dark:
        let g = CGGradient(colorsSpace: cs, colors: [rgb(0x221836), rgb(0x0A0710)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: S, y: S), options: all)
    case .tinted:
        ctx.setFillColor(rgb(0x000000))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    }

    ctx.translateBy(x: 0, y: -14)
    // Cuore con freccia scavata, disegnato in un livello a parte (per l'ombra).
    if v == .light {
        ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 48, color: rgb(0x2A0A5E, 0.40))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(heartPath())
    switch v {
    case .light, .tinted:
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
    case .dark:
        ctx.saveGState()
        ctx.clip()
        let g = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFF8466), rgb(0xFF4D86), rgb(0xA45CFF)] as CFArray,
                           locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 220, y: 200), end: CGPoint(x: 800, y: 860), options: all)
        ctx.restoreGState()
    }
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(76)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(arrowPath())
    ctx.strokePath()
    ctx.endTransparencyLayer()

    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("scritto \(url.path)")
}

save(render(.light), "AppIcon.png")
save(render(.dark), "AppIcon-Dark.png")
save(render(.tinted), "AppIcon-Tinted.png")
