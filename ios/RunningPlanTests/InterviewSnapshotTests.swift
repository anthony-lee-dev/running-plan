import SwiftUI
import Testing
import UIKit
@testable import RunningPlan

/// Compares the rendered screen with the dark board in designs/dark/png on a coarse colour grid.
/// Fonts (Bricolage Grotesque, Inter) are not bundled yet and every simulator frames the window a little
/// differently, so exact pixels or an absolute threshold would not hold across machines. The tests compare
/// relatively instead: the right render must sit closer to the board than a wrong one. That catches layout, colour
/// and selection regressions, not typography.
@MainActor
struct InterviewSnapshotTests {
    private static let columns = 26
    private static let rows = 56
    private func board(_ name: String) throws -> CGImage {
        // This file is ios/RunningPlanTests/..., so the repo root is two levels up.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("designs/dark/png/\(name).png")
        let image = try #require(UIImage(contentsOfFile: url.path), "missing \(url.path)")
        return try #require(image.cgImage)
    }

    /// Draws the real view hierarchy (ImageRenderer leaves out UIKit-backed views such as ScrollView).
    private func render(_ flow: InterviewFlow) throws -> CGImage {
        let size = CGSize(width: 390, height: 844)
        let host = UIHostingController(rootView: InterviewView(flow: flow, onFinish: { _, _ in }, onClose: {}))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // The boards leave 62 pt at the top for the status bar; make the top inset that, whatever the simulator gives.
        host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, 62 - host.view.safeAreaInsets.top), left: 0, bottom: 0, right: 0)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        return try #require(image.cgImage)
    }

    /// Average colour of each cell of a coarse grid, as RGB values in 0...1.
    private func grid(_ image: CGImage) -> [Double] {
        let bytesPerRow = Self.columns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Self.rows)
        let context = CGContext(
            data: &pixels, width: Self.columns, height: Self.rows, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
        return pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) / 255 }
    }

    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let (ga, gb) = (grid(a), grid(b))
        return zip(ga, gb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(ga.count)
    }

    private func firstQuestionWithTenKSelected() -> InterviewFlow {
        let flow = InterviewFlow()
        flow.setDistance(.tenK)
        return flow
    }

    @Test func questionOneIsCloserToTheBoardThanADifferentQuestion() throws {
        let boardImage = try board("DK-Interview")
        let right = difference(try render(firstQuestionWithTenKSelected()), boardImage)
        let flow = firstQuestionWithTenKSelected()
        flow.next()  // question 2: a different layout
        let other = difference(try render(flow), boardImage)
        #expect(right < other, "question 1 (\(right)) should be closer to DK-Interview than question 2 (\(other))")
    }

    @Test func theSelectedCardIsPartOfTheComparison() throws {
        let boardImage = try board("DK-Interview")
        let flow = InterviewFlow()
        flow.setDistance(.fiveK)
        let wrongSelection = difference(try render(flow), boardImage)
        let right = difference(try render(firstQuestionWithTenKSelected()), boardImage)
        #expect(right < wrongSelection, "10K selected (\(right)) should be closer than 5K selected (\(wrongSelection))")
    }
}
