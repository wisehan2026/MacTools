import AppKit
import Foundation

// 使用原生矢量图形生成图标，不依赖外部图片或第三方服务。
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.57, alpha: 1), ending: NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.35, alpha: 1))!
gradient.draw(in: background, angle: -55)
let slots: [(CGFloat, CGFloat, String)] = [(236, 556, "clipboard"), (556, 556, "crop"), (236, 236, "magnifyingglass"), (556, 236, "record.circle")]
for (x, y, symbol) in slots {
    let rect = NSRect(x: x - 28, y: y - 28, width: 260, height: 260)
    NSColor.white.withAlphaComponent(0.1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 55, yRadius: 55).fill()
    if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 155, weight: .regular).applying(.init(paletteColors: [.white]))) {
        icon.draw(in: NSRect(x: x + 12, y: y + 12, width: 180, height: 180))
    }
}
image.unlockFocus()
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
