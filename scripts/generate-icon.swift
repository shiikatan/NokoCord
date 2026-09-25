import AppKit

// The canonical mascot is never redrawn or recolored. Only its neutral
// backdrop is removed so the unchanged foreground can sit above a glass plate.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Branding/NokoCord.png")
let source = NSImage(contentsOf: sourceURL)!
let foreground = foregroundImage(from: source)
let output = root.appendingPathComponent("NokoCord/Assets.xcassets/AppIcon.appiconset")

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let raster = CGContext(data: nil, width: pixels, height: pixels,
                               bitsPerComponent: 8, bytesPerRow: pixels * 4,
                               space: colorSpace, bitmapInfo: bitmapInfo)!
        raster.interpolationQuality = .high

        let plate = CGRect(x: side * 0.09, y: side * 0.09,
                           width: side * 0.82, height: side * 0.82)
        let platePath = CGPath(roundedRect: plate, cornerWidth: side * 0.19,
                               cornerHeight: side * 0.19, transform: nil)
        raster.saveGState()
        raster.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                         blur: side * 0.025, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        raster.addPath(platePath)
        raster.setFillColor(glassColor(0x17232E))
        raster.fillPath()
        raster.restoreGState()

        raster.saveGState()
        raster.addPath(platePath)
        raster.clip()
        let base = CGGradient(colorsSpace: colorSpace, colors: [
            glassColor(0x536575), glassColor(0x303E4D), glassColor(0x18232E)
        ] as CFArray, locations: [0, 0.52, 1])!
        raster.drawLinearGradient(base,
                                  start: CGPoint(x: plate.minX, y: plate.maxY),
                                  end: CGPoint(x: plate.maxX, y: plate.minY),
                                  options: [])

        // Reflections belong to the plate and stay behind the mascot.
        let halo = CGGradient(colorsSpace: colorSpace, colors: [
            NSColor.white.withAlphaComponent(0.21).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 1])!
        raster.drawRadialGradient(halo,
                                  startCenter: CGPoint(x: plate.minX + side * 0.32,
                                                       y: plate.maxY - side * 0.23),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: plate.minX + side * 0.32,
                                                     y: plate.maxY - side * 0.23),
                                  endRadius: side * 0.62,
                                  options: [])
        let sheen = CGGradient(colorsSpace: colorSpace, colors: [
            NSColor.white.withAlphaComponent(0.17).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 1])!
        raster.drawLinearGradient(sheen,
                                  start: CGPoint(x: plate.midX, y: plate.maxY),
                                  end: CGPoint(x: plate.midX, y: plate.maxY - side * 0.30),
                                  options: [])
        raster.restoreGState()

        raster.addPath(platePath)
        raster.setStrokeColor(NSColor.white.withAlphaComponent(0.23).cgColor)
        raster.setLineWidth(max(0.45, side / 800))
        raster.strokePath()

        let characterFrame = plate
        raster.saveGState()
        raster.addPath(platePath)
        raster.clip()
        raster.setShadow(offset: CGSize(width: side * 0.008, height: -side * 0.014),
                         blur: side * 0.023, color: NSColor.black.withAlphaComponent(0.57).cgColor)
        raster.draw(foreground, in: characterFrame)
        raster.restoreGState()

        let bitmap = NSBitmapImageRep(cgImage: raster.makeImage()!)
        let data = bitmap.representation(using: .png, properties: [:])!
        try withoutMetadata(data).write(to: output.appendingPathComponent("icon-\(size)@\(scale)x.png"))
    }
}

func glassColor(_ hex: Int) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1).cgColor
}

func foregroundImage(from image: NSImage) -> CGImage {
    let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let width = original.width
    let height = original.height
    let rowBytes = width * 4
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    pixels.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: rowBytes,
                                space: colorSpace, bitmapInfo: bitmapInfo)!
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // The original backdrop is nearly neutral gray. Flood from the image edge
    // through only neutral pixels. This retains dark eyes enclosed by the face
    // and preserves every opaque mascot color from the canonical artwork.
    func isBackdrop(_ index: Int) -> Bool {
        let offset = index * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        return max(red, green, blue) - min(red, green, blue) <= 12
    }
    var background = [UInt8](repeating: 0, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height / 2)
    func enqueue(_ index: Int) {
        if background[index] == 0 && isBackdrop(index) {
            background[index] = 1
            queue.append(index)
        }
    }
    for x in 0..<width {
        enqueue(x)
        enqueue((height - 1) * width + x)
    }
    for y in 0..<height {
        enqueue(y * width)
        enqueue(y * width + width - 1)
    }
    var head = 0
    while head < queue.count {
        let index = queue[head]
        head += 1
        let x = index % width
        let y = index / width
        if x > 0 { enqueue(index - 1) }
        if x + 1 < width { enqueue(index + 1) }
        if y > 0 { enqueue(index - width) }
        if y + 1 < height { enqueue(index + width) }
    }
    for index in 0..<background.count where background[index] != 0 {
        let offset = index * 4
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = 0
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8,
                   bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                   provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)!
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
