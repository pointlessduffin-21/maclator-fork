// Draws the Maclator icon: a rosette (rosetta, "little rose") on a paper tile, ringed by an arrow
// that runs counter-clockwise: translation running the other way round. Paper palette: paper
// ground, ink lines, one vermilion accent (one petal and the arrow head).
// Usage: swift icon.swift out.png [size]

import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let size = CGFloat(args.count > 2 ? Double(args[2])! : 1024)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let paper = rgb(0xF5F2EB), paperHi = rgb(0xFAF8F3), paperLo = rgb(0xEBE6DB)
let ink = rgb(0x1C1B18), ink3 = rgb(0x8A857A), accent = rgb(0xD2462F)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
let s = size / 1024 // everything below is laid out on a 1024 canvas

// macOS icon grid: an 824pt continuous-corner tile centred on the canvas, with a soft shadow.
let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).cgPath
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0x1C1B18, 0.22))
g.addPath(tilePath); g.setFillColor(paper); g.fillPath()
g.restoreGState()
g.addPath(tilePath); g.setFillColor(paper); g.fillPath()
// A raised inner sheet, as Paper does with paper-hi surfaces, and the hairline edge.
g.saveGState()
g.addPath(tilePath); g.clip()
g.setFillColor(paperHi)
g.fillEllipse(in: CGRect(x: 170 * s, y: 170 * s, width: 684 * s, height: 684 * s))
g.restoreGState()
g.addPath(tilePath); g.setStrokeColor(rgb(0x1C1B18, 0.12)); g.setLineWidth(3 * s); g.strokePath()

let c = CGPoint(x: 512 * s, y: 512 * s)

// The rosette: eight petals, ink outlines on paper; the petal at "ten o'clock" is vermilion.
let petals = 8
let accentPetal = 3
// Draw the vermilion petal last so it sits on top of its neighbours.
for i in (0..<petals).filter({ $0 != accentPetal }) + [accentPetal] {
    let angle = CGFloat(i) * .pi * 2 / CGFloat(petals) + .pi / 8
    g.saveGState()
    g.translateBy(x: c.x, y: c.y)
    g.rotate(by: angle)
    // A petal: a pointed ellipse from the centre outwards.
    let p = CGMutablePath()
    let len = 205 * s, w = 70 * s
    p.move(to: CGPoint(x: 0, y: 0))
    p.addCurve(to: CGPoint(x: len, y: 0), control1: CGPoint(x: len * 0.25, y: w), control2: CGPoint(x: len * 0.8, y: w * 0.9))
    p.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: len * 0.8, y: -w * 0.9), control2: CGPoint(x: len * 0.25, y: -w))
    let highlighted = i == accentPetal
    g.addPath(p)
    g.setFillColor(highlighted ? accent : paperHi)
    g.fillPath()
    g.addPath(p)
    g.setStrokeColor(highlighted ? accent : ink)
    g.setLineWidth(9 * s)
    g.setLineJoin(.round)
    g.strokePath()
    // the vein
    if !highlighted {
        g.move(to: CGPoint(x: 34 * s, y: 0)); g.addLine(to: CGPoint(x: len * 0.72, y: 0))
        g.setStrokeColor(ink3); g.setLineWidth(4 * s); g.setLineCap(.round); g.strokePath()
    }
    g.restoreGState()
}
// The heart of the rose.
g.setFillColor(ink)
g.fillEllipse(in: CGRect(x: c.x - 34 * s, y: c.y - 34 * s, width: 68 * s, height: 68 * s))
g.setFillColor(paperHi)
g.fillEllipse(in: CGRect(x: c.x - 12 * s, y: c.y - 12 * s, width: 24 * s, height: 24 * s))

// The ring: a counter-clockwise arrow round the rosette, open at the top right, with a vermilion head.
let r = 300 * s
// Nearly a full turn, anticlockwise from `start`; the head stops short of the tail dot.
let start = CGFloat.pi * 0.58, end = start + CGFloat.pi * 1.80
g.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
g.setStrokeColor(ink); g.setLineWidth(16 * s); g.setLineCap(.round); g.strokePath()
// Arrow head at `end`, pointing along the counter-clockwise tangent.
let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
let tangent = CGPoint(x: -sin(end), y: cos(end)) // direction of travel for an anticlockwise arc
let normal = CGPoint(x: cos(end), y: sin(end))
let headLen = 70 * s, headW = 42 * s
let point = CGPoint(x: tip.x + tangent.x * headLen * 0.55, y: tip.y + tangent.y * headLen * 0.55)
let back = CGPoint(x: tip.x - tangent.x * headLen * 0.45, y: tip.y - tangent.y * headLen * 0.45)
g.move(to: point)
g.addLine(to: CGPoint(x: back.x + normal.x * headW, y: back.y + normal.y * headW))
g.addLine(to: CGPoint(x: back.x - normal.x * headW, y: back.y - normal.y * headW))
g.closePath()
g.setFillColor(accent); g.fillPath()
// The tail: a small ink dot where the arrow starts.
let tail = CGPoint(x: c.x + r * cos(start), y: c.y + r * sin(start))
g.setFillColor(ink)
g.fillEllipse(in: CGRect(x: tail.x - 15 * s, y: tail.y - 15 * s, width: 30 * s, height: 30 * s))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
