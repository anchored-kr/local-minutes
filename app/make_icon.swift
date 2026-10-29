// 앱 아이콘을 그려 AppIcon.iconset 에 PNG 로 쓴다. 사용: swift make_icon.swift <iconset 폴더>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS 아이콘 격자: 전체의 약 80% 크기 둥근 사각형
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.32, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1)])!.draw(in: path, angle: -90)
    // 파형 막대: 왼쪽(나) 파랑, 오른쪽(상대) 주황
    let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.36, 0.5, 0.28, 0.46, 0.66, 0.4, 0.24]
    let barW = rect.width * 0.052
    let gap = rect.width * 0.03
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    for (i, h) in heights.enumerated() {
        let bh = rect.height * h
        let bar = NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        (i < heights.count / 2 ? NSColor(calibratedRed: 0.38, green: 0.66, blue: 1, alpha: 1)
                               : NSColor(calibratedRed: 1, green: 0.66, blue: 0.3, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    // 아래 자물쇠 점: 이 맥 안에서만
    let dot = rect.width * 0.07
    NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.5, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: rect.minY + rect.height * 0.1, width: dot, height: dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
