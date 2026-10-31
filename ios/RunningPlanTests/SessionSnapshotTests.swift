import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Editor against its board, relatively (see `BoardSnapshot`). Text is pinned by
/// `SessionSheetModelTests` and `SessionDraftTests`; these check layout and colour.
///
/// DK-Session has no board comparison: on its tall board (1412 pt, with the Add to Apple Watch button that task 4.2
/// adds) the coarse grid scored a strength sheet, a rest day and even the editor nearer than the intervals sheet, so
/// a relative check would pin nothing. Its content is pinned by `SessionSheetModelTests`; here it is only the
/// editor's board, and the sheet serves as the editor's "different screen".
@MainActor
struct SessionSnapshotTests {
    private func sheet(on date: String, board: CGImage) throws -> CGImage {
        let model = SessionSheetModel(schedule: try SessionSheetModelTests.schedule(), session: try SessionSheetModelTests.session(on: date))
        return try BoardSnapshot.render(SessionView(model: model), like: board)
    }

    private func editor(on date: String, board: CGImage) throws -> CGImage {
        let session = try SessionSheetModelTests.session(on: date)
        let view = SessionEditorView(
            mode: .edit, span: "2026-10-05"..."2026-12-13", onCancel: {}, onSave: { _ in nil }, draft: SessionDraft(session.value2)
        )
        return try BoardSnapshot.render(view, like: board)
    }

    @Test func theIntervalsEditorIsNearerItsBoardThanAnotherSessionOrScreen() throws {
        let board = try BoardSnapshot.board("DK-Editor")
        let right = BoardSnapshot.difference(try editor(on: "2026-10-28", board: board), board)
        let strength = BoardSnapshot.difference(try editor(on: "2026-10-27", board: board), board)
        let sheet = BoardSnapshot.difference(try sheet(on: "2026-10-28", board: board), board)
        #expect(right < strength, "the intervals editor (\(right)) should be nearer the board than strength (\(strength))")
        #expect(right < sheet, "the editor (\(right)) should be nearer its board than the session sheet (\(sheet))")
    }
}
