// Draws Mirage's app icon (an original neon dusk: striped sun over a road) into an .iconset.
//   xcrun swift Tools/make-icon.swift build/Mirage.iconset && iconutil -c icns build/Mirage.iconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 rounded square, centred.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1a1238))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    let horizon = tile.minY + tile.height * 0.42
    // Sky (CoreGraphics y grows upwards).
    let sky = CGGradient(colorsSpace: space, colors: [color(0xff8a4c), color(0xe8457c), color(0x7b2fa8), color(0x1d1446)] as CFArray,
                         locations: [0, 0.22, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: tile.maxY), options: [])
    // Sun with horizontal cut-outs.
    let sunRadius = tile.width * 0.27
    let sunCenter = CGPoint(x: tile.midX, y: horizon + sunRadius * 0.55)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius))
    ctx.clip()
    let sun = CGGradient(colorsSpace: space, colors: [color(0xff4f7b), color(0xff9f45), color(0xffe27a)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sun, start: CGPoint(x: 0, y: sunCenter.y - sunRadius), end: CGPoint(x: 0, y: sunCenter.y + sunRadius), options: [])
    ctx.setBlendMode(.clear)
    for i in 0..<6 {
        let y = sunCenter.y - sunRadius * 0.05 - CGFloat(i) * sunRadius * 0.17
        ctx.fill(CGRect(x: sunCenter.x - sunRadius, y: y, width: 2 * sunRadius, height: sunRadius * (0.025 + 0.018 * CGFloat(i))))
    }
    ctx.restoreGState()
    // Ground with a perspective grid.
    let ground = CGGradient(colorsSpace: space, colors: [color(0x0c0820), color(0x231048)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: horizon - tile.minY))
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: horizon), options: [])
    ctx.setStrokeColor(color(0xff4fa3, 0.85))
    ctx.setLineWidth(max(1, s * 0.004))
    for i in -9...9 {
        ctx.move(to: CGPoint(x: tile.midX + CGFloat(i) * tile.width * 0.012, y: horizon))
        ctx.addLine(to: CGPoint(x: tile.midX + CGFloat(i) * tile.width * 0.2, y: tile.minY))
    }
    for k in 1...7 {
        let z = CGFloat(k) / 7
        let y = horizon - (horizon - tile.minY) * z * z
        ctx.move(to: CGPoint(x: tile.minX, y: y))
        ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
    }
    ctx.strokePath()
    // Road with a centre line.
    ctx.setFillColor(color(0x0a0716))
    ctx.move(to: CGPoint(x: tile.midX - tile.width * 0.02, y: horizon))
    ctx.addLine(to: CGPoint(x: tile.midX + tile.width * 0.02, y: horizon))
    ctx.addLine(to: CGPoint(x: tile.midX + tile.width * 0.36, y: tile.minY))
    ctx.addLine(to: CGPoint(x: tile.midX - tile.width * 0.36, y: tile.minY))
    ctx.fillPath()
    ctx.setFillColor(color(0xffd36e))
    for k in 0..<5 {
        let z0 = (CGFloat(k) + 0.15) / 5, z1 = (CGFloat(k) + 0.55) / 5
        let y0 = horizon - (horizon - tile.minY) * z0 * z0, y1 = horizon - (horizon - tile.minY) * z1 * z1
        let w0 = tile.width * (0.004 + 0.02 * z0), w1 = tile.width * (0.004 + 0.02 * z1)
        ctx.move(to: CGPoint(x: tile.midX - w0, y: y0))
        ctx.addLine(to: CGPoint(x: tile.midX + w0, y: y0))
        ctx.addLine(to: CGPoint(x: tile.midX + w1, y: y1))
        ctx.addLine(to: CGPoint(x: tile.midX - w1, y: y1))
        ctx.fillPath()
    }
    ctx.restoreGState()
    // Horizon glow line.
    ctx.setFillColor(color(0xffb1d6, 0.9))
    ctx.fill(CGRect(x: tile.minX, y: horizon - s * 0.002, width: tile.width, height: max(1, s * 0.004)))
    ctx.restoreGState()
    return ctx.makeImage()!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = output.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, drawIcon(size: base * scale), nil)
        CGImageDestinationFinalize(destination)
    }
}
