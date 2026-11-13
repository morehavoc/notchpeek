// Renders NotchPeek's app icon to AppIcon.icns. Run: swift make_icon.swift
import AppKit
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024
    // Squircle body (Apple grid: 824 px body inside 1024 canvas)
    let body = NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185*u, yRadius: 185*u)
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = 24*u; sh.shadowOffset = NSSize(width: 0, height: -10*u); sh.set()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.55, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.55, green: 0.33, blue: 0.92, alpha: 1)])!
        .draw(in: shape, angle: -70)
    NSGraphicsContext.current?.restoreGraphicsState()
    shape.addClip()
    // Menu bar band
    let barH: CGFloat = 120*u
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSRect(x: body.minX, y: body.maxY - barH, width: body.width, height: barH).fill()
    // Notch
    let nw: CGFloat = 300*u, nh: CGFloat = 150*u
    let notch = NSBezierPath(roundedRect: NSRect(x: body.midX - nw/2, y: body.maxY - nh, width: nw, height: nh + 60*u), xRadius: 50*u, yRadius: 50*u)
    NSColor.black.setFill(); notch.fill()
    // Tiny menu bar dots either side
    NSColor.white.withAlphaComponent(0.9).setFill()
    for x in [180, 250, 740, 810] as [CGFloat] {
        NSBezierPath(ovalIn: NSRect(x: x*u, y: body.maxY - barH/2 - 20*u, width: 40*u, height: 40*u)).fill()
    }
    // Glass pill dropping out of the notch with three icons
    let pill = NSRect(x: body.midX - 280*u, y: body.maxY - nh - 260*u, width: 560*u, height: 190*u)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 70*u, yRadius: 70*u)
    NSColor.white.withAlphaComponent(0.92).setFill(); pillPath.fill()
    let colors = [NSColor.systemOrange, NSColor.systemGreen, NSColor.systemPink]
    for (i, c) in colors.enumerated() {
        let r = NSRect(x: pill.minX + 50*u + CGFloat(i) * 160*u, y: pill.midY - 60*u, width: 140*u, height: 120*u)
        c.setFill(); NSBezierPath(roundedRect: r, xRadius: 28*u, yRadius: 28*u).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "preview.png"))
