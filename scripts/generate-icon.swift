import AppKit
// Packages the canonical artwork; never redraws or recolors its design.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let source = NSImage(contentsOf: root.appendingPathComponent("Branding/NokoCord.png"))!
let out = root.appendingPathComponent("NokoCord/Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let raster = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let context = NSGraphicsContext(cgContext: raster, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let side = CGFloat(pixels)
        // Match the optical footprint of a conventional macOS rounded-square icon.
        let frame = NSRect(x: side * 0.10, y: side * 0.10, width: side * 0.80, height: side * 0.80)
        let shape = NSBezierPath(roundedRect: frame, xRadius: side * 0.18, yRadius: side * 0.18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = side * 0.018
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        source.draw(in: frame, from: .zero, operation: .copy, fraction: 1)
        // A container edge separates dark artwork from a dark Dock. Artwork is unchanged.
        NSColor.white.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = max(0.35, side / 1024)
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: raster.makeImage()!)
        try withoutMetadata(bitmap.representation(using: .png, properties: [:])!).write(to: out.appendingPathComponent("icon-\(size)@\(scale)x.png"))
    }
}

// Strip optional identifying metadata while retaining compressed pixel bytes.
func withoutMetadata(_ data: Data) -> Data {
    let bytes = [UInt8](data)
    var result = Data(bytes.prefix(8))
    var offset = 8
    while offset + 12 <= bytes.count {
        let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        let end = offset + 12 + length
        precondition(end <= bytes.count, "Invalid PNG chunk")
        let kind = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)!
        if !["eXIf", "tEXt", "zTXt", "iTXt"].contains(kind) { result.append(contentsOf: bytes[offset..<end]) }
        offset = end
    }
    precondition(offset == bytes.count, "Invalid PNG length")
    return result
}
