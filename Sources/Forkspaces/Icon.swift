import AppKit
import ImageIO

let profileColors = ["#D97757", "#6688CC", "#779978", "#A080BF", "#C59C50", "#619A9B"]

func validColor(_ hex: String) -> Bool { hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil }

func colorValue(_ hex: String) -> NSColor {
    let number = UInt32(hex.dropFirst(), radix: 16) ?? 0xD97757
    return NSColor(srgbRed: CGFloat((number >> 16) & 255) / 255,
                   green: CGFloat((number >> 8) & 255) / 255,
                   blue: CGFloat(number & 255) / 255, alpha: 1)
}

func hexValue(_ color: NSColor) -> String? {
    guard let c = color.usingColorSpace(.sRGB) else { return nil }
    return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}

/// Loads PNG/JPEG/HEIC natively, applies EXIF orientation, center-crops to a square and returns a 1024 px PNG.
func squareIconPNG(from url: URL) throws -> Data {
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw Failure("This image could not be read. Choose a PNG, JPEG or HEIC file.") }
    let side = min(image.width, image.height)
    guard side >= 16, let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) else {
        throw Failure("This image is too small for an icon.")
    }
    let rep = try bitmap(1024) { NSImage(cgImage: square, size: .zero).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)) }
    guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("Cannot encode icon.") }
    return png
}

private func bitmap(_ pixels: Int, _ draw: () -> Void) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure("Cannot draw profile icon.") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // NSBitmapImageRep memory is not zeroed; clear it so transparent corners never contain garbage.
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func iconBitmap(_ pixels: Int, initial: String, color: String, image: NSImage?) throws -> NSBitmapImageRep {
    try bitmap(pixels) {
        let s = CGFloat(pixels)
        let frame = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
        let shape = NSBezierPath(roundedRect: frame, xRadius: s * 0.20, yRadius: s * 0.20)
        if let image {
            shape.addClip()
            image.draw(in: frame)
            return
        }
        colorValue(color).setFill()
        shape.fill()
        let letter = initial as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * (initial.count > 1 ? 0.42 : 0.57), weight: .semibold),
                                                   .foregroundColor: NSColor.white]
        let extent = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: (s - extent.width) / 2, y: (s - extent.height) / 2), withAttributes: attrs)
    }
}

func iconPreview(initial: String, color: String, image: NSImage?) -> NSImage {
    let preview = NSImage(size: NSSize(width: 64, height: 64))
    if let rep = try? iconBitmap(256, initial: initial, color: color, image: image) { preview.addRepresentation(rep) }
    return preview
}

func makeIcon(initial: String, color: String, image: NSImage? = nil, at url: URL) throws {
    try writeICNS(at: url) { try iconBitmap($0, initial: initial, color: color, image: image) }
}

/// Forkspaces' own icon: one root splitting into two separate spaces.
func makeAppIcon(at url: URL) throws {
    try writeICNS(at: url) { pixels in try bitmap(pixels) { drawAppIcon(CGFloat(pixels)) } }
}

private func drawAppIcon(_ s: CGFloat) {
    let p = { (x: CGFloat, y: CGFloat) in NSPoint(x: s * x, y: s * y) }
    let shape = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.20, blue: 0.25, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1))?.draw(in: shape, angle: -90)
    let ink = NSColor(white: 0.93, alpha: 1)
    let fork = NSBezierPath()
    fork.lineWidth = s * 0.05; fork.lineCapStyle = .round
    fork.move(to: p(0.5, 0.28)); fork.line(to: p(0.5, 0.44))
    fork.move(to: p(0.5, 0.44)); fork.curve(to: p(0.34, 0.6), controlPoint1: p(0.5, 0.53), controlPoint2: p(0.34, 0.5))
    fork.move(to: p(0.5, 0.44)); fork.curve(to: p(0.66, 0.6), controlPoint1: p(0.5, 0.53), controlPoint2: p(0.66, 0.5))
    ink.setStroke(); fork.stroke()
    ink.setFill(); NSBezierPath(ovalIn: NSRect(x: s * 0.455, y: s * 0.235, width: s * 0.09, height: s * 0.09)).fill()
    for (x, color) in [(0.34, NSColor(srgbRed: 0.25, green: 0.76, blue: 0.69, alpha: 1)), (0.66, NSColor(srgbRed: 0.55, green: 0.49, blue: 0.94, alpha: 1))] {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: s * (x - 0.085), y: s * 0.58, width: s * 0.17, height: s * 0.17), xRadius: s * 0.045, yRadius: s * 0.045).fill()
    }
}

/// Renders every iconset size and lets macOS' own iconutil encode the .icns.
private func writeICNS(at url: URL, _ render: (Int) throws -> NSBitmapImageRep) throws {
    let iconset = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iconset")
    try ensureDirectory(iconset)
    defer { try? fileManager.removeItem(at: iconset) }
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            guard let png = try render(points * scale).representation(using: .png, properties: [:]) else { throw Failure("Cannot encode icon.") }
            try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
        }
    }
    let output = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).icns")
    do { try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path]) }
    catch { throw Failure("macOS could not encode the icon.") }
    _ = try fileManager.replaceItemAt(url, withItemAt: output)
}
