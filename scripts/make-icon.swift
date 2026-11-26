// Draws the app icon at 1024×1024: a window breaking into glowing pixels.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt squircle centered with a soft shadow.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x140F33))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0x2A1B5E), color(0x120C2C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft spotlight
let spot = CGGradient(colorsSpace: cs, colors: [color(0x7B5CFF, 0.45), color(0x7B5CFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(spot, startCenter: CGPoint(x: 600, y: 600), startRadius: 0, endCenter: CGPoint(x: 600, y: 600), endRadius: 520, options: [])

// The window (left part intact).
let win = CGRect(x: 205, y: 300, width: 470, height: 360)
let winPath = CGPath(roundedRect: win, cornerWidth: 44, cornerHeight: 44, transform: nil)
let cut: CGFloat = 520  // x where the window starts to disintegrate
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.4))
ctx.addPath(winPath)
ctx.clip(to: CGRect(x: 0, y: 0, width: cut, height: size))
ctx.addPath(winPath)
ctx.setFillColor(color(0xF6F5FB))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(winPath)
ctx.clip()
ctx.clip(to: CGRect(x: 0, y: 0, width: cut, height: size))
// Title bar + content blocks
ctx.setFillColor(color(0xE7E4F3))
ctx.fill(CGRect(x: win.minX, y: win.maxY - 70, width: win.width, height: 70))
let lights: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
for (i, c) in lights.enumerated() {
    ctx.setFillColor(color(c))
    ctx.fillEllipse(in: CGRect(x: win.minX + 34 + CGFloat(i) * 42, y: win.maxY - 48, width: 26, height: 26))
}
let hero = CGRect(x: win.minX + 34, y: win.minY + 120, width: 400, height: 140)
let heroPath = CGPath(roundedRect: hero, cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.addPath(heroPath)
ctx.saveGState()
ctx.clip()
let heroG = CGGradient(colorsSpace: cs, colors: [color(0xFF9A62), color(0xF25C8A), color(0x6C5BFF)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(heroG, start: CGPoint(x: hero.minX, y: hero.minY), end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
ctx.restoreGState()
ctx.setFillColor(color(0xD8D4EA))
for i in 0..<2 {
    let w: CGFloat = i == 0 ? 380 : 260
    ctx.addPath(CGPath(roundedRect: CGRect(x: win.minX + 34, y: win.minY + 74 - CGFloat(i) * 34, width: w, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()
}
ctx.restoreGState()

// Pixels flying off to the upper right, shrinking and taking on color.
var rng = SystemRandomNumberGenerator()
struct Px { var x: CGFloat; var y: CGFloat; var s: CGFloat; var c: UInt32; var a: CGFloat }
var pixels: [Px] = []
let palette: [UInt32] = [0xF6F5FB, 0xC9B8FF, 0x8FD3FF, 0xFF9AC1, 0xFFC86B]
let cell: CGFloat = 30
var gy = win.minY
var row = 0
while gy < win.maxY - 4 {
    var gx = cut
    var col = 0
    while gx < win.maxX + 330 {
        let d = gx - cut
        let pIntact = max(0, 1 - d / 120)
        if gx < win.maxX && Double.random(in: 0...1, using: &rng) < pIntact * 0.9 {
            pixels.append(Px(x: gx, y: gy, s: cell - 4, c: 0xF6F5FB, a: 1))
        } else {
            let travel = d / 400
            let prob = max(0, 0.55 - travel * 0.45)
            if Double.random(in: 0...1, using: &rng) < prob {
                let s = max(8, (cell - 4) * (1 - travel * 0.75)) * CGFloat.random(in: 0.7...1.1, using: &rng)
                let lift = d * 0.42 + CGFloat.random(in: -18...18, using: &rng)
                let c = palette[(row + col + Int.random(in: 0...4, using: &rng)) % palette.count]
                pixels.append(Px(x: gx, y: gy + lift, s: s, c: c, a: max(0.2, 1 - travel * 0.8)))
            }
        }
        gx += cell
        col += 1
    }
    gy += cell
    row += 1
}
for p in pixels where p.y + p.s < tile.maxY - 40 && p.x + p.s < tile.maxX - 40 {
    ctx.saveGState()
    if p.c != 0xF6F5FB {
        ctx.setShadow(offset: .zero, blur: p.s * 0.9, color: color(p.c, 0.9))
    }
    ctx.setFillColor(color(p.c, p.a))
    ctx.addPath(CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: p.s, height: p.s), cornerWidth: p.s * 0.22, cornerHeight: p.s * 0.22, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

// Top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// Hairline border
ctx.addPath(tilePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
