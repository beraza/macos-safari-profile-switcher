// Draws the app icon and writes Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // macOS icon grid: the shape takes ~80% of the canvas.
    let inset = size * 0.1
    let shape = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: shape, xRadius: shape.width * 0.225, yRadius: shape.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.12, green: 0.55, blue: 1, alpha: 1),
                        NSColor(red: 0.36, green: 0.27, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -90)
    let configuration = NSImage.SymbolConfiguration(pointSize: shape.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let fit = symbol.size
        symbol.draw(in: NSRect(x: shape.midX - fit.width / 2, y: shape.midY - fit.height / 2,
                               width: fit.width, height: fit.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
