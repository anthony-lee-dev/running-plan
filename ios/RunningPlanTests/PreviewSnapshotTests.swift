import APIClient
import SwiftUI
import Testing
import UIKit
@testable import RunningPlan

private final class OneShotGenerator: PlanGenerating {
    let draft: Components.Schemas.PlanDraft
    init(_ draft: Components.Schemas.PlanDraft) { self.draft = draft }
    func generate(answers: InterviewAnswers, today: String) async throws -> Components.Schemas.PlanDraft { draft }
}

private final class NoStore: PreviewDraftStoring {
    func save(_ preview: SavedPreview) {}
    func load(now: Date) -> SavedPreview? { nil }
    func clear() {}
}

/// Compares the rendered screen with `designs/dark/png/DK-Preview.png` on a coarse colour grid, relatively (the right
/// plan must be nearer the board than a wrong one), for the reasons in `InterviewSnapshotTests`.
@MainActor
struct PreviewSnapshotTests {
    private static let columns = 26
    private static let rows = 80

    private func board() throws -> CGImage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("designs/dark/png/DK-Preview.png")
        return try #require(UIImage(contentsOfFile: url.path)?.cgImage, "missing \(url.path)")
    }

    private func model(_ draft: Components.Schemas.PlanDraft?) async -> PreviewViewModel {
        let vm = PreviewViewModel(
            answers: InterviewAnswers(),
            generator: OneShotGenerator(draft ?? (try! DraftFixture.draft())),
            store: NoStore(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            today: { "2026-11-02" }
        )
        await vm.load()
        return vm
    }

    private func render(_ vm: PreviewViewModel) throws -> CGImage {
        // The board is 390 pt wide and about 1261 pt tall, with 62 pt at the top for the status bar.
        let size = CGSize(width: 390, height: 1261)
        let host = UIHostingController(rootView: PreviewView(model: vm, onChangeAnswer: {}, onSave: {}))
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

    /// A horizontal band of an image, as fractions of its height.
    private func band(_ image: CGImage, from: Double, to: Double) -> CGImage {
        let h = Double(image.height)
        return image.cropping(to: CGRect(x: 0, y: h * from, width: Double(image.width), height: h * (to - from))) ?? image
    }

    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let (ga, gb) = (grid(a), grid(b))
        return zip(ga, gb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(ga.count)
    }

    @Test func thePlanIsNearerTheBoardThanAPlanWithOtherPhasesAndDistances() async throws {
        let boardImage = try board()
        let right = difference(try render(await model(nil)), boardImage)
        let flat = try DraftFixture.draft(weeklyKm: Array(repeating: 12, count: 10), phases: Array(repeating: "taper", count: 10))
        let wrong = difference(try render(await model(flat)), boardImage)
        #expect(right < wrong, "the board's plan (\(right)) should be nearer than a flat taper plan (\(wrong))")
    }

    @Test func theChartMatchesTheBoardsBarsNotJustTheLayout() async throws {
        // Same layout, same phases, but the weeks run the other way round: only the bars differ.
        let boardChart = band(try board(), from: 0.17, to: 0.395)
        let right = difference(band(try render(await model(nil)), from: 0.17, to: 0.395), boardChart)
        let reversed = try DraftFixture.draft(weeklyKm: DraftFixture.weeklyKm.reversed())
        let wrong = difference(band(try render(await model(reversed)), from: 0.17, to: 0.395), boardChart)
        #expect(right < wrong, "the board's bars (\(right)) should be nearer than reversed bars (\(wrong))")
    }

    @Test func aLoadedPlanIsNearerTheBoardThanTheLoadingScreen() async throws {
        let boardImage = try board()
        let loaded = difference(try render(await model(nil)), boardImage)
        let loading = PreviewViewModel(answers: InterviewAnswers(), generator: OneShotGenerator(try DraftFixture.draft()), store: NoStore())
        #expect(loaded < difference(try render(loading), boardImage))
    }
}
