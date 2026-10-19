import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { bounds in
            let s = CGFloat(pixels) / 1024
            let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 35*s, dy: 35*s), xRadius: 210*s, yRadius: 210*s)
            NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.46, blue: 0.94, alpha: 1), ending: NSColor(srgbRed: 0.08, green: 0.23, blue: 0.64, alpha: 1))!.draw(in: background, angle: -60)
            let back = NSBezierPath(roundedRect: NSRect(x: 194*s, y: 370*s, width: 570*s, height: 385*s), xRadius: 50*s, yRadius: 50*s)
            NSColor.white.withAlphaComponent(0.28).setFill(); back.fill()
            NSColor.white.withAlphaComponent(0.65).setStroke(); back.lineWidth = 13*s; back.stroke()
            let frontRect = NSRect(x: 290*s, y: 235*s, width: 570*s, height: 385*s)
            let front = NSBezierPath(roundedRect: frontRect, xRadius: 50*s, yRadius: 50*s)
            NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: 1).setFill(); front.fill()
            NSColor.white.setStroke(); front.lineWidth = 13*s; front.stroke()
            NSColor(srgbRed: 0.26, green: 0.53, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 335*s, y: 515*s, width: 36*s, height: 36*s), xRadius: 8*s, yRadius: 8*s).fill()
            NSColor(srgbRed: 0.56, green: 0.68, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 395*s, y: 524*s, width: 235*s, height: 17*s), xRadius: 8*s, yRadius: 8*s).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
