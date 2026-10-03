// Renders icons/icon.svg to every PNG the app needs, without alpha (App Store requirement).
// Run from the repo root: swift scripts/make_icons.swift
import AppKit

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("first-mile-icon")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let ql = Process()
ql.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
ql.arguments = ["-t", "-s", "1024", "-o", tmp.path, "icons/icon.svg"]
ql.standardOutput = FileHandle.nullDevice
try! ql.run(); ql.waitUntilExit()
let source = NSImage(contentsOf: tmp.appendingPathComponent("icon.svg.png"))!

let outputs: [(String, Int)] = [
    ("icons/app-store-icon-1024.png", 1024),
    ("icons/icon-512.png", 512),
    ("icons/icon-192.png", 192),
    ("icons/apple-touch-icon.png", 180),
    ("ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png", 1024),
]
for (path, size) in outputs {
    if path.hasPrefix("ios/") && !FileManager.default.fileExists(atPath: "ios") { continue }
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    var rect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.draw(source.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(size)px)")
}
