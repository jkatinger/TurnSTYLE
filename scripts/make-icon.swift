import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(red: 0.025, green: 0.028, blue: 0.035, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 218, yRadius: 218).fill()
        let brandBlue = NSColor(red: 0.42, green: 0.68, blue: 1.0, alpha: 1)
        brandBlue.setStroke()
        brandBlue.setFill()
        let upper = NSBezierPath()
        upper.move(to: NSPoint(x: 240, y: 565))
        upper.line(to: NSPoint(x: 240, y: 655))
        upper.curve(
            to: NSPoint(x: 345, y: 760), controlPoint1: NSPoint(x: 240, y: 720), controlPoint2: NSPoint(x: 280, y: 760))
        upper.line(to: NSPoint(x: 750, y: 760))
        upper.lineWidth = 88
        upper.lineCapStyle = .round
        upper.lineJoinStyle = .round
        upper.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 665, y: 860))
        arrow.line(to: NSPoint(x: 770, y: 760))
        arrow.line(to: NSPoint(x: 665, y: 660))
        arrow.lineWidth = 88
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
        let lower = NSBezierPath()
        lower.move(to: NSPoint(x: 784, y: 459))
        lower.line(to: NSPoint(x: 784, y: 369))
        lower.curve(
            to: NSPoint(x: 679, y: 264), controlPoint1: NSPoint(x: 784, y: 304), controlPoint2: NSPoint(x: 744, y: 264))
        lower.line(to: NSPoint(x: 274, y: 264))
        lower.lineWidth = 88
        lower.lineCapStyle = .round
        lower.lineJoinStyle = .round
        lower.stroke()
        let back = NSBezierPath()
        back.move(to: NSPoint(x: 359, y: 164))
        back.line(to: NSPoint(x: 254, y: 264))
        back.line(to: NSPoint(x: 359, y: 364))
        back.lineWidth = 88
        back.lineCapStyle = .round
        back.lineJoinStyle = .round
        back.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(filename))
    }
}
