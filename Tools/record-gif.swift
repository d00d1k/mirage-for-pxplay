// Records part of one app window into an animated GIF (for the README), without bringing it forward.
//   xcrun swift Tools/record-gif.swift "Mirage Installer" out.gif <seconds> <cropTopPt> <cropHeightPt> <widthPx>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let owner = args[1], output = args[2]
let seconds = Double(args[3])!, cropTop = Double(args[4])!, cropHeight = Double(args[5])!, width = Int(args[6])!

func findWindow() -> (Int, CGFloat)? {
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where (window[kCGWindowOwnerName as String] as? String) == owner
        && (window[kCGWindowLayer as String] as? Int) == 0 {
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        if (bounds["Height"] ?? 0) > 300, let number = window[kCGWindowNumber as String] as? Int {
            return (number, bounds["Width"] ?? 1)
        }
    }
    return nil
}

var found: (Int, CGFloat)?
for _ in 0..<80 where found == nil { found = findWindow(); if found == nil { Thread.sleep(forTimeInterval: 0.1) } }
guard let (windowID, windowWidth) = found else { fputs("window not found\n", stderr); exit(1) }

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-gif-\(getpid()).png")
var frames: [(CGImage, Double)] = []
let start = Date()
var last = start
while Date().timeIntervalSince(start) < seconds {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(windowID), temp.path]
    try task.run()
    task.waitUntilExit()
    guard let source = CGImageSourceCreateWithURL(temp as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    let scale = CGFloat(image.width) / windowWidth
    guard let cropped = image.cropping(to: CGRect(x: 0, y: cropTop * scale, width: CGFloat(image.width), height: cropHeight * scale)) else { continue }
    let height = Int(Double(width) * Double(cropped.height) / Double(cropped.width))
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    let now = Date()
    if !frames.isEmpty { frames[frames.count - 1].1 = now.timeIntervalSince(last) }
    frames.append((context.makeImage()!, 0.1))
    last = now
}
try? FileManager.default.removeItem(at: temp)
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (index, frame) in frames.enumerated() {
    let delay = index == frames.count - 1 ? 1.5 : max(0.02, frame.1)
    CGImageDestinationAddImage(destination, frame.0,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
}
CGImageDestinationFinalize(destination)
print("\(frames.count) frames → \(output)")
