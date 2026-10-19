// Regenerate Resources/AppIcon.icns using the menu bar's orbit design.
// Run from the repository root: swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let background = NSBezierPath(
        roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
        xRadius: 204, yRadius: 204
    )
    NSGradient(colors: [
        NSColor(srgbRed: 0.12, green: 0.15, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.36, blue: 0.77, alpha: 1)
    ])!.draw(in: background, angle: 65)

    let orbitTransform = NSAffineTransform()
    orbitTransform.translateX(by: 116, yBy: 116)
    orbitTransform.scale(by: 44)
    orbitTransform.concat()

    NSColor.white.set()
    let orbit = NSBezierPath()
    orbit.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6,
                    startAngle: 70, endAngle: 380)
    orbit.lineWidth = 1.4
    orbit.lineCapStyle = .round
    orbit.stroke()
    NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
    NSColor(srgbRed: 0.40, green: 0.92, blue: 0.91, alpha: 1).set()
    NSBezierPath(ovalIn: NSRect(x: 11.1, y: 11.1, width: 4.4, height: 4.4)).fill()
    NSGraphicsContext.current?.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try render(pixels: size * factor).write(
            to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        )
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
