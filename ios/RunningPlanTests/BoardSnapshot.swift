import SwiftUI
import Testing
import UIKit

/// Renders a screen at a DK board's size and compares the two on a coarse colour grid. Comparisons are relative (the
/// right render must be nearer the board than a wrong one), for the reasons in `InterviewSnapshotTests`.
@MainActor
enum BoardSnapshot {
    static let columns = 26
    static let rows = 80

    static func board(_ name: String) throws -> CGImage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("designs/dark/png/\(name).png")
        return try #require(UIImage(contentsOfFile: url.path)?.cgImage, "missing \(url.path)")
    }

    /// The view at the board's size in points (boards are 3x), with 62 pt at the top for the status bar.
    static func render<V: View>(_ view: V, like board: CGImage) throws -> CGImage {
        let size = CGSize(width: Double(board.width) / 3, height: Double(board.height) / 3)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, 62 - host.view.safeAreaInsets.top), left: 0, bottom: 0, right: 0)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        return try #require(image.cgImage)
    }

    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let (ga, gb) = (grid(a), grid(b))
        return zip(ga, gb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(ga.count)
    }

    private static func grid(_ image: CGImage) -> [Double] {
        let bytesPerRow = columns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let context = CGContext(
            data: &pixels, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) / 255 }
    }
}
