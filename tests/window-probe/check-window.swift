// check-window TITLE COLOR OUTPUT.png: capture the on-screen window whose title contains TITLE
// and check that its client area is filled with COLOR (green, magenta or blue).
//
// The capture (screencapture -l, without shadow) is kept in OUTPUT.png. Points on a 9x9 grid
// are sampled, leaving out the top 40 points (title bar, if any) and a 4% margin; each must be
// clearly the expected primary color, after conversion to sRGB. Exit 0 when all are, 1 when not,
// 2 when the window or the capture is missing. Needs Screen Recording permission for the
// terminal (window titles and contents).
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: check-window TITLE COLOR OUTPUT.png", code: 2) }
let (title, colorName, output) = (arguments[1], arguments[2], arguments[3])
let expected: (r: Bool, g: Bool, b: Bool)
switch colorName {
case "green": expected = (false, true, false)
case "magenta": expected = (true, false, true)
case "blue": expected = (false, false, true)
default: fail("unknown color \(colorName)", code: 2)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: { ($0[kCGWindowName as String] as? String ?? "").contains(title) }),
      let windowID = window[kCGWindowNumber as String] as? Int
else { fail("no on-screen window titled \"\(title)\"", code: 2) }

let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l\(windowID)", output]
try capture.run()
capture.waitUntilExit()
guard capture.terminationStatus == 0,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: output) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("capture of window \(windowID) failed", code: 2) }

// Redraw in sRGB so the display profile does not change the primaries.
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else { fail("cannot read the capture", code: 2) }

let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
let scale = CGFloat(width) / max(bounds["Width"] ?? CGFloat(width), 1)
let top = min(Int(40 * scale), height / 4)
var wrong: [String] = []
for row in 0..<9 {
    for column in 0..<9 {
        let x = Int(Double(width) * (0.04 + 0.92 * Double(column) / 8))
        let y = top + Int(Double(height - top) * (0.04 + 0.92 * Double(row) / 8))
        let offset = (min(y, height - 1) * width + min(x, width - 1)) * 4
        let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        func on(_ value: UInt8, _ wanted: Bool) -> Bool { wanted ? value >= 160 : value <= 90 }
        if !(on(r, expected.r) && on(g, expected.g) && on(b, expected.b)) {
            wrong.append("(\(x),\(y))=\(r),\(g),\(b)")
        }
    }
}
let size = "\(width)x\(height) px, window \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0)) pt"
if wrong.isEmpty {
    print("ok \(colorName): \(size)")
} else {
    print("WRONG \(colorName): \(wrong.count)/81 points, \(size); first: \(wrong.prefix(4).joined(separator: " "))")
    exit(1)
}
