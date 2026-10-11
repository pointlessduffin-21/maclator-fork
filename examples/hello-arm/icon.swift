// Draws the Hello.app icon: a chip outline with pins on a paper tile, "ARM" in Instrument Serif,
// one vermilion pin-1 dot. Usage: swift icon.swift out.png [size] [InstrumentSerif-Regular.ttf]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let size = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
if args.count > 3 { CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[3]) as CFURL, .process, nil) }
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let paper = rgb(0xF5F2EB), paperHi = rgb(0xFAF8F3), ink = rgb(0x1C1B18), accent = rgb(0xD2462F)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
let s = size / 1024
let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).cgPath
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0x1C1B18, 0.22))
g.addPath(tilePath); g.setFillColor(paper); g.fillPath()
g.restoreGState()
g.addPath(tilePath); g.setStrokeColor(rgb(0x1C1B18, 0.12)); g.setLineWidth(3 * s); g.strokePath()

// pins
g.setStrokeColor(ink); g.setLineWidth(14 * s); g.setLineCap(.round)
let die = CGRect(x: 292 * s, y: 292 * s, width: 440 * s, height: 440 * s)
for i in 0..<4 {
    let t = die.minX + (CGFloat(i) + 0.5) * die.width / 4
    let u = die.minY + (CGFloat(i) + 0.5) * die.height / 4
    g.move(to: CGPoint(x: t, y: die.maxY)); g.addLine(to: CGPoint(x: t, y: die.maxY + 70 * s))
    g.move(to: CGPoint(x: t, y: die.minY)); g.addLine(to: CGPoint(x: t, y: die.minY - 70 * s))
    g.move(to: CGPoint(x: die.minX, y: u)); g.addLine(to: CGPoint(x: die.minX - 70 * s, y: u))
    g.move(to: CGPoint(x: die.maxX, y: u)); g.addLine(to: CGPoint(x: die.maxX + 70 * s, y: u))
}
g.strokePath()
let diePath = NSBezierPath(roundedRect: die, xRadius: 56 * s, yRadius: 56 * s).cgPath
g.addPath(diePath); g.setFillColor(paperHi); g.fillPath()
g.addPath(diePath); g.setStrokeColor(ink); g.setLineWidth(14 * s); g.strokePath()
g.setFillColor(accent)
g.fillEllipse(in: CGRect(x: die.minX + 34 * s, y: die.maxY - 34 * s - 28 * s, width: 28 * s, height: 28 * s))

let font = NSFont(name: "InstrumentSerif-Regular", size: 190 * s) ?? NSFont.systemFont(ofSize: 150 * s)
let str = NSAttributedString(string: "ARM", attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!, .kern: -3 * s])
let sz = str.size()
str.draw(at: CGPoint(x: die.midX - sz.width / 2, y: die.midY - sz.height / 2 - 4 * s))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
