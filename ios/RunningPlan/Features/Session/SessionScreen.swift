import APIClient
import SwiftUI

/// What the plan screens open over themselves: a session's spec sheet, the editor for a new session, or the move sheet.
enum SessionRoute: Identifiable, Hashable {
    case open(sessionId: String)
    case add(date: String)
    case move(sessionId: String)

    var id: String {
        switch self {
        case .open(let id): "open \(id)"
        case .add(let date): "add \(date)"
        case .move(let id): "move \(id)"
        }
    }
}

/// DK-Session for a session of the loaded plan, with its editor and the move sheet. Every change goes straight to the
/// API through `PlanStore`; the sheet redraws from the store, so it always shows the server's copy.
struct SessionScreen: View {
    let plans: PlanStore
    let sessionId: String
    var watchSync: WatchSyncModel?
    let onClose: () -> Void

    @State private var editing = false
    @State private var moving = false
    @State private var busy = false
    @State private var error: String?
    @State private var checkedIn: BeforeFeeling?
    /// One before-session check-in per visit; a retry after a lost answer reuses the id.
    @State private var checkInID = UUID().uuidString.lowercased()

    var body: some View {
        if let plan = plans.plan, let session = plan.value2.sessions.first(where: { $0.value1.id == sessionId && $0.value1.deletedAt == nil }) {
            let schedule = PlanSchedule(plan: plan, today: PreviewViewModel.localToday())
            SessionView(
                model: SessionSheetModel(schedule: schedule, session: session),
                busy: busy, error: error, checkedIn: checkedIn,
                watchPlan: WatchWorkoutMapper.plan(for: session), watchSync: watchSync,
                onToggleWatchSync: { toggleWatchSync(plan) },
                onBack: onClose,
                onEdit: { editing = true },
                onAdjust: { adjust($0, session) },
                onSwap: { moving = true },
                onCheckIn: { checkIn($0) }
            )
            .sheet(isPresented: $editing) {
                SessionEditor(plans: plans, session: session, onClose: { deleted in
                    editing = false
                    if deleted { onClose() }
                })
            }
            .sheet(isPresented: $moving) {
                MoveSheet(plans: plans, sessionId: sessionId, onClose: { moving = false })
            }
        } else {
            VStack(spacing: 16) {
                Text("This session is no longer in your plan.").font(.system(size: 16)).foregroundStyle(Palette.muted.color)
                Button("Back", action: onClose).foregroundStyle(Palette.accentText.color).frame(minHeight: Metrics.minTouchTarget)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bg.color.ignoresSafeArea())
        }
    }

    private func toggleWatchSync(_ plan: Components.Schemas.PlanDetail) {
        guard let watchSync else { return }
        Task {
            if watchSync.isOn {
                await watchSync.turnOff()
            } else {
                await watchSync.turnOn(sessions: plan.value2.sessions, today: PreviewViewModel.localToday())
            }
        }
    }

    private func adjust(_ adjustment: QuickAdjustment, _ session: Components.Schemas.Session) {
        guard let update = adjustment.update(for: session.value2) else { return }
        run { await plans.apply([SessionEdit(sessionId: session.value1.id, revision: session.value1.revision, update: update)]) }
    }

    private func checkIn(_ feeling: BeforeFeeling) {
        run {
            let failed = await plans.checkIn(sessionId: sessionId, feeling: feeling, id: checkInID)
            if failed == nil { checkedIn = feeling }
            return failed
        }
    }

    private func run(_ body: @escaping () async -> String?) {
        busy = true
        error = nil
        Task {
            error = await body()
            busy = false
        }
    }
}

/// The editor bound to the store: edits an existing session (or, with `date`, adds one) and closes once saved.
struct SessionEditor: View {
    let plans: PlanStore
    var session: Components.Schemas.Session?
    var date: String?
    /// Called with true when the session was deleted.
    let onClose: (Bool) -> Void
    @State private var newID = UUID().uuidString.lowercased()

    var body: some View {
        if let plan = plans.plan {
            let fields = plan.value1.value2
            let last = PlanSchedule.date(dayNumber: PlanPreview.dayNumber(fields.startDate) + fields.weekCount * 7 - 1)
            let span = fields.startDate...max(fields.startDate, last)
            if let session {
                SessionEditorView(
                    mode: .edit, span: span,
                    headsUp: plan.value2.warnings.filter { $0.sessionIds?.contains(session.value1.id) == true }.map(\.message),
                    onCancel: { onClose(false) },
                    onSave: { draft in
                        guard let update = draft.update(from: session.value2) else {
                            onClose(false)
                            return nil
                        }
                        let failed = await plans.apply([SessionEdit(sessionId: session.value1.id, revision: session.value1.revision, update: update)])
                        if failed == nil { onClose(false) }
                        return failed
                    },
                    onDelete: {
                        let failed = await plans.delete(sessionId: session.value1.id, revision: session.value1.revision)
                        if failed == nil { onClose(true) }
                        return failed
                    },
                    draft: SessionDraft(session.value2)
                )
            } else {
                SessionEditorView(
                    mode: .create, span: span,
                    onCancel: { onClose(false) },
                    onSave: { draft in
                        // One id per editor, so a retry after a lost answer replays rather than adding a second session.
                        let failed = await plans.create(draft.create(id: newID))
                        if failed == nil { onClose(false) }
                        return failed
                    },
                    draft: SessionDraft.new(date: min(max(date ?? fields.startDate, span.lowerBound), span.upperBound))
                )
            }
        }
    }
}

/// Swap: pick another day of the week. Whatever is on that day takes this session's place; Skip is offered here too
/// (Move or skip on Next opens this sheet).
struct MoveSheet: View {
    let plans: PlanStore
    let sessionId: String
    let onClose: () -> Void

    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let plan = plans.plan, let session = plan.value2.sessions.first(where: { $0.value1.id == sessionId && $0.value1.deletedAt == nil }) {
                    let schedule = PlanSchedule(plan: plan, today: PreviewViewModel.localToday())
                    Section {
                        ForEach(QuickAdjustment.moveOptions(session, in: schedule), id: \.date) { option in
                            Button(option.label) { send(QuickAdjustment.move(session, to: option.date, in: schedule)) }
                                .foregroundStyle(Palette.ink.color)
                                .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
                        }
                    } header: {
                        Text("Move \(session.value2.title ?? SessionSummary.effort(session.value2)) to")
                    } footer: {
                        Text("Moving or skipping marks the session as yours.")
                    }
                    if let skip = QuickAdjustment.skip.update(for: session.value2), session.value2.status != .skipped {
                        Section {
                            Button("Skip this session", role: .destructive) {
                                send([SessionEdit(sessionId: session.value1.id, revision: session.value1.revision, update: skip)])
                            }
                        } footer: {
                            Text("A skipped session is never crammed in later.")
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(Palette.accentText.color)
                    }
                }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden)
            .background(Palette.bg.color.ignoresSafeArea())
            .navigationTitle("Move or skip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
            }
        }
        .tint(Palette.accentText.color)
        .preferredColorScheme(.dark)
    }

    private func send(_ edits: [SessionEdit]) {
        guard !edits.isEmpty else { return onClose() }
        busy = true
        error = nil
        Task {
            error = await plans.apply(edits)
            busy = false
            if error == nil { onClose() }
        }
    }
}
