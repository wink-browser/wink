// Builds Wink's brand assets from the logo artwork:
//   - AppIcon.icns (+ a 1024 px PNG): the eye reprinted on coral paper,
//     set into the macOS icon grid (an 824 pt rounded square, 100 pt margin,
//     soft shadow);
//   - WinkEye.png: the eye alone on transparency, for agent presence in the
//     UI (cursor, pill, prompts, panel). Its alpha matte is derived from the
//     artwork itself (keying out the mustard paper), never a drawn shape.
//   The artwork keeps its original mustard paper: that saturated paper is what
//   lets the eye key out cleanly. Only the icon swaps it for coral.
//   - Winky.jpg + WinkyAvatar.png (optional third argument: Winky's portrait):
//     the welcome-screen portrait and the circle-ready face crop for Winky,
//     Wink's assistant.
//
//   make icon
//   (or: swiftc scripts/make_icon.swift -o build/make_icon &&
//        build/make_icon Resources/Brand/wink-eye.jpg Resources/AppIcon.icns [Resources/Brand/winky.jpg])

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4,
      let source = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make_icon <artwork.jpg|png> <out.icns> [winky.jpg]\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])

/// The brand paper: coral, #FC9A7C (Theme.coralNS).
let coral = (r: 252.0, g: 154.0, b: 124.0)

// MARK: - The paper

/// How much of a pixel is eye rather than paper. Keyed on "yellowness",
/// (R+G)/2 − B, which separates the mustard paper (and its texture and
/// shading) from the cobalt, white and black of the eye.
func eyeAlpha(_ r: Double, _ g: Double, _ b: Double) -> Double {
    let t = min(1, max(0, ((r + g) / 2 - b - 38) / (92 - 38)))
    return 1 - t * t * (3 - 2 * t)  // smoothstep
}

/// The paper's colour, from the corners of an RGBA buffer.
func paperColor(_ pixels: [UInt8], width w: Int, height h: Int) -> (r: Double, g: Double, b: Double) {
    var sum = (r: 0.0, g: 0.0, b: 0.0), samples = 0.0
    for (cx, cy) in [(0, 0), (w - 60, 0), (0, h - 60), (w - 60, h - 60)] {
        for y in cy..<(cy + 60) { for x in cx..<(cx + 60) {
            let i = (y * w + x) * 4
            sum.r += Double(pixels[i]); sum.g += Double(pixels[i + 1]); sum.b += Double(pixels[i + 2]); samples += 1
        } }
    }
    return (sum.r / samples, sum.g / samples, sum.b / samples)
}

/// Reprints the artwork on new paper. The eye is untouched; the paper, and the
/// paper's share of every edge pixel, shifts to `target` and keeps its grain,
/// so the lashes carry no fringe of the old paper.
func repaper(_ image: CGImage, to target: (r: Double, g: Double, b: Double)) -> CGImage? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let paper = paperColor(pixels, width: w, height: h)
    let shift = (r: target.r - paper.r, g: target.g - paper.g, b: target.b - paper.b)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
        let share = 1 - eyeAlpha(r, g, b)
        guard share > 0 else { continue }
        pixels[i] = UInt8(min(255, max(0, (r + share * shift.r).rounded())))
        pixels[i + 1] = UInt8(min(255, max(0, (g + share * shift.g).rounded())))
        pixels[i + 2] = UInt8(min(255, max(0, (b + share * shift.b).rounded())))
    }
    return context.makeImage()
}

// Square crop centred on the eye (the artwork is centred), reprinted on coral.
let side = min(source.width, source.height)
let art = repaper(source.cropping(to: CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2,
                                             width: side, height: side))!, to: coral)!

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    // Lift off the Dock with a soft shadow (drawn with the paper's coral so
    // the edge never shows a dark fringe).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                      color: NSColor.black.withAlphaComponent(0.32).cgColor)
    NSColor(srgbRed: coral.r / 255, green: coral.g / 255, blue: coral.b / 255, alpha: 1).setFill()
    squircle.fill()
    context.restoreGState()

    context.saveGState()
    squircle.addClip()
    context.draw(art, in: body)
    context.restoreGState()

    // A hairline keeps the edge crisp on light backgrounds.
    NSColor.black.withAlphaComponent(0.10).setStroke()
    squircle.lineWidth = 2
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Wink-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let data = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
}
let png = output.deletingPathExtension().appendingPathExtension("png")
try drawIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: png)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

// MARK: - The eye, cut out

func cutOutEye(from image: CGImage, width outputWidth: Int) -> Data? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    let paper = paperColor(pixels, width: w, height: h)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            let alpha = eyeAlpha(r, g, b)
            if alpha < 0.004 {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                continue
            }
            // Un-mix the paper from edge pixels so lashes carry no yellow fringe.
            func unmix(_ c: Double, _ m: Double) -> UInt8 {
                let e = (c - (1 - alpha) * m) / alpha
                return UInt8(min(255, max(0, e * alpha)))  // premultiplied
            }
            pixels[i] = unmix(r, paper.r); pixels[i + 1] = unmix(g, paper.g); pixels[i + 2] = unmix(b, paper.b)
            pixels[i + 3] = UInt8(alpha * 255)
            if alpha > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX > minX, maxY > minY, let keyed = context.makeImage() else { return nil }
    let margin = 6
    let crop = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                      width: min(w, maxX + margin) - max(0, minX - margin), height: min(h, maxY + margin) - max(0, minY - margin))
    guard let eye = keyed.cropping(to: crop) else { return nil }
    let outputHeight = Int((Double(outputWidth) * Double(eye.height) / Double(eye.width)).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outputWidth, pixelsHigh: outputHeight, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.interpolationQuality = .high
    NSGraphicsContext.current!.cgContext.draw(eye, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let eyeOutput = output.deletingLastPathComponent().appendingPathComponent("WinkEye.png")
guard let eyeData = cutOutEye(from: source, width: 360) else {
    FileHandle.standardError.write("could not cut out the eye\n".data(using: .utf8)!)
    exit(1)
}
try eyeData.write(to: eyeOutput)
print("✓ \(output.path), \(png.lastPathComponent) and \(eyeOutput.lastPathComponent)")

// MARK: - Winky

/// Crops a rectangle given as fractions of the image (origin top-left) and
/// scales it to `width` pixels.
func crop(_ image: CGImage, x: Double, y: Double, w: Double, h: Double, width: Int) -> NSBitmapImageRep? {
    let rect = CGRect(x: x * Double(image.width), y: y * Double(image.height),
                      width: w * Double(image.width), height: h * Double(image.height)).integral
    guard let cut = image.cropping(to: rect) else { return nil }
    let height = Int((Double(width) * Double(cut.height) / Double(cut.width)).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.interpolationQuality = .high
    NSGraphicsContext.current!.cgContext.draw(cut, in: CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if arguments.count == 4, let winky = NSImage(contentsOfFile: arguments[3])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let folder = output.deletingLastPathComponent()
    // Portrait: head and shoulders, with room on the side she looks toward.
    if let portrait = crop(winky, x: 0.13, y: 0.02, w: 0.63, h: 0.98, width: 960),
       let data = portrait.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
        try data.write(to: folder.appendingPathComponent("Winky.jpg"))
    }
    // Avatar: the face, square, for a circle mask.
    if let avatar = crop(winky, x: 0.19, y: 0.085, w: 0.39, h: 0.52, width: 512),
       let data = avatar.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
        try data.write(to: folder.appendingPathComponent("WinkyAvatar.jpg"))
    }
    print("✓ Winky.jpg and WinkyAvatar.jpg")
}
