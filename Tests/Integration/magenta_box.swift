// Prints the bounding box (in points) of pure-magenta pixels in a screenshot, and how filled it is.
import Foundation
import CoreGraphics
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("no image"); exit(1) }
let w = img.width, h = img.height
var data = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var minX = w, minY = h, maxX = -1, maxY = -1, count = 0
// Only rows holding a long unbroken run of the colour count: small magenta things elsewhere on screen are ignored.
for y in 0..<h {
    var run = 0, best = 0, bestEnd = 0
    for x in 0..<w {
        let i = (y * w + x) * 4
        if data[i] > 235 && data[i+1] < 40 && data[i+2] > 235 { run += 1; if run > best { best = run; bestEnd = x } } else { run = 0 }
    }
    if best >= 300 { count += best; let start = bestEnd - best + 1; if start < minX { minX = start }; if bestEnd > maxX { maxX = bestEnd }; if y < minY { minY = y }; if y > maxY { maxY = y } }
}
let scale = Double(w) / (Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1800") ?? 1800)
if maxX < 0 { print("magenta: none (image \(w)x\(h))"); exit(0) }
let bw = maxX - minX + 1, bh = maxY - minY + 1
print(String(format: "magenta box: origin=(%.1f,%.1f) size=%.1fx%.1f pt  filled=%.0f%%  (image %dx%d, scale %.2f)", Double(minX)/scale, Double(minY)/scale, Double(bw)/scale, Double(bh)/scale, 100.0 * Double(count) / Double(bw * bh), w, h, scale))
