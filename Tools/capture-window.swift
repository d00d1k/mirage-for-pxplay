// Saves a screenshot of one app's window without bringing it to the front.
//   xcrun swift Tools/capture-window.swift "Mirage Installer" out.png
import CoreGraphics
import Foundation

let owner = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
for _ in 0..<60 {
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    if let window = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == owner
            && ($0[kCGWindowLayer as String] as? Int) == 0
            && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 300 }),
       let number = window[kCGWindowNumber as String] as? Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(number), output]
        try task.run()
        task.waitUntilExit()
        exit(task.terminationStatus)
    }
    Thread.sleep(forTimeInterval: 0.25)
}
FileHandle.standardError.write("window not found\n".data(using: .utf8)!)
exit(1)
