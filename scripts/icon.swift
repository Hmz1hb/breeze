import AppKit
import Foundation

let destination = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: destination).deletingLastPathComponent().appendingPathComponent("Breeze.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let box = NSRect(x: side*0.06, y: side*0.06, width: side*0.88, height: side*0.88)
        NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: side*0.21, yRadius: side*0.21).fill()
        if let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "Breeze") {
            let config = NSImage.SymbolConfiguration(pointSize: side*0.60, weight: .regular)
                .applying(.init(paletteColors: [NSColor(calibratedRed: 0.73, green: 0.96, blue: 0.85, alpha: 1)]))
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            configured.draw(in: NSRect(x: side*0.20, y: side*0.20, width: side*0.60, height: side*0.60))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot draw icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", destination]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: directory)
