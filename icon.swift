import Cocoa
// usage: icon <out.png> <size> <second letter>
let out = CommandLine.arguments[1], s = CGFloat(Int(CommandLine.arguments[2])!)
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let m = s * 0.06, r = NSRect(x: m, y: m, width: s - 2*m, height: s - 2*m)
let path = NSBezierPath(roundedRect: r, xRadius: s*0.22, yRadius: s*0.22)
NSGradient(colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.90, alpha: 1)])!.draw(in: path, angle: -90)
// soft top highlight
NSColor(white: 0, alpha: 0.18).setStroke(); path.lineWidth = s * 0.004; path.stroke()
NSGraphicsContext.current?.saveGraphicsState(); path.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.0), NSColor(white: 1, alpha: 0)])!.draw(in: NSRect(x: 0, y: s*0.5, width: s, height: s*0.5), angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()
func font(_ sz: CGFloat) -> NSFont {
    NSFont(name: "HelveticaNeue-Bold", size: sz) ?? NSFont.systemFont(ofSize: sz, weight: .bold)
}
let fF = font(s * 0.56), fo = font(s * 0.40)
let a1: [NSAttributedString.Key: Any] = [.font: fF, .foregroundColor: NSColor.black]
let a2: [NSAttributedString.Key: Any] = [.font: fo, .foregroundColor: NSColor.black]
let F = NSAttributedString(string: "F", attributes: a1), o = NSAttributedString(string: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "o", attributes: a2)
let w = F.size().width + o.size().width - s*0.02
let x = (s - w) / 2
let baseline = s * 0.5 - fF.capHeight / 2
let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.18); sh.shadowOffset = NSSize(width: 0, height: -s*0.012); sh.shadowBlurRadius = s*0.03; sh.set()
F.draw(at: NSPoint(x: x, y: baseline + fF.descender))
o.draw(at: NSPoint(x: x + F.size().width - s*0.02, y: baseline + fo.descender))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
