import SwiftUI

/// DK-Inbox: workouts found in Health (or added by hand) waiting to be matched to the plan. System fonts until the font task.
struct InboxScreen: View {
    let store: InboxStore
    let plans: PlanStore
    let onClose: () -> Void
    @State private var picking: String?
    /// A session chosen in the picker: confirmed once the sheet has gone, so the check-in can be presented after it.
    @State private var picked: (activityId: String, choice: InboxModel.Choice)?
    @State private var manual = false
    @State private var showAllRuns = false

    var body: some View {
        let model = store.model(today: PreviewViewModel.localToday())
        // Read here, not only in the binding, so the cover appears when a match is confirmed.
        let checkIn = store.pendingCheckIn
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        Text("Next").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Back to Next")
                Text("Import inbox")
                    .font(.system(size: 32, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.inbox")
                if model.cards.isEmpty {
                    Text(store.loaded ? "All caught up" : "Looking for workouts")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                        .accessibilityIdentifier("inbox.empty")
                } else {
                    Text(model.subtitle).font(.system(size: 16)).foregroundStyle(Palette.muted.color)
                }
                if let confirmed = store.lastConfirmed {
                    HStack {
                        Text("Matched to \(confirmed.label)").font(.system(size: 14)).foregroundStyle(Palette.greenSoftText.color)
                        Spacer()
                        Button("Undo") { Task { await store.undo() } }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                            .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                            .accessibilityIdentifier("inbox.undo")
                    }
                }
                if let error = store.error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("inbox.error")
                }
                ForEach(model.cards) { card in
                    InboxCardView(card: card, busy: store.busy, store: store, onPick: { picking = card.id })
                }
                if model.missedCount > 0 {
                    Text("\(model.missedCount) planned \(model.missedCount == 1 ? "session has" : "sessions have") no workout yet. \"Match to a session\" lists missed days too.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .task {
            // A check-in left from a match that finished after the inbox closed is not popped up on this visit.
            store.finishCheckIn()
            await store.load()
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), onDismiss: {
            guard let pick = picked else { return }
            picked = nil
            Task { await store.confirm(activityId: pick.activityId, sessionId: pick.choice.id, label: pick.choice.title) }
        }) {
            if let id = picking {
                SessionPicker(choices: model.choices(for: id), emptyNote: model.emptyChoicesNote(for: id), onPick: { choice in
                    picked = (id, choice)
                    picking = nil
                }, onClose: { picking = nil })
            }
        }
        .fullScreenCover(item: Binding(get: { checkIn }, set: { if $0 == nil { store.finishCheckIn() } })) { target in
            CheckInScreen(plans: plans, target: target, onClose: { store.finishCheckIn(saved: $0) })
        }
        .sheet(isPresented: $manual) { ManualRunSheet(store: store, onClose: { manual = false }) }
        .fullScreenCover(isPresented: $showAllRuns) { RunsScreen(store: store, onClose: { showAllRuns = false }) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.lastSynced.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? "")
                .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                + Text("If a run didn't come through from your watch app, you can add it by hand.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
            if store.healthAvailable {
                textButton("Check Health for new workouts", id: "inbox.sync") { Task { await store.syncHealth() } }
            }
            textButton("Add a run manually", id: "inbox.manual") { manual = true }
            textButton("All imported runs", id: "inbox.allRuns") { showAllRuns = true }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    private func textButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                .frame(minHeight: Metrics.minTouchTarget, alignment: .leading).contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }
}

private struct InboxCardView: View {
    let card: InboxModel.Card
    let busy: Bool
    let store: InboxStore
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(card.heading).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                Spacer()
                badge
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.headline).font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                if !card.detail.isEmpty {
                    Text(card.detail).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.muted.color)
                }
            }
            switch card.kind {
            case .likelyMatch(let sessionId, let label):
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Matches your plan").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                        Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    }
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(Palette.green.color)
                }
                .padding(14)
                .background(Palette.bg.color, in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 10) {
                    Button { Task { await store.confirm(activityId: card.id, sessionId: sessionId, label: label) } } label: {
                        Text("Confirm match").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("inbox.confirm")
                    SecondaryButton(title: "Change", action: onPick).frame(width: 110).accessibilityIdentifier("inbox.change")
                }
            case .extraRun:
                Text("Nothing was planned that day. Nice bonus. Adding it keeps your totals honest.")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                HStack(spacing: 10) {
                    Button { Task { await store.addAsExtra(card.id) } } label: {
                        Text("Add as extra run").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.bg.color)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Palette.ink.color, in: RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("inbox.addExtra")
                    SecondaryButton(title: "Match to a session", action: onPick).accessibilityIdentifier("inbox.match")
                }
                ignoreButton
            case .otherWorkout:
                Text("Nothing like this was planned that day. Match it to a session, or leave it out.")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                SecondaryButton(title: "Match to a session", action: onPick).accessibilityIdentifier("inbox.match")
                ignoreButton
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .disabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.card")
    }

    private var ignoreButton: some View {
        Button { Task { await store.ignore(card.id) } } label: {
            Text("Ignore this workout").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.muted.color)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget).contentShape(Rectangle())
        }
        .accessibilityIdentifier("inbox.ignore")
    }

    @ViewBuilder private var badge: some View {
        switch card.kind {
        case .likelyMatch: pill("Likely match", Palette.greenSoft.color, Palette.greenSoftText.color)
        case .extraRun: pill("Extra run", Palette.blueSoft.color, Palette.blueText.color)
        case .otherWorkout: pill("Other workout", Palette.blueSoft.color, Palette.blueText.color)
        }
    }

    private func pill(_ text: String, _ fill: Color, _ ink: Color) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            .padding(.vertical, 5).padding(.horizontal, 10).background(fill, in: Capsule())
    }
}

struct SessionPicker: View {
    let choices: [InboxModel.Choice]
    let emptyNote: String?
    let onPick: (InboxModel.Choice) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let emptyNote {
                    Text(emptyNote).foregroundStyle(Palette.muted.color)
                }
                ForEach(choices) { choice in
                    Button { onPick(choice) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                            Text(choice.when).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                        }
                        .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
                    }
                    .accessibilityIdentifier("inbox.pick")
                    .listRowBackground(Palette.card.color)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg.color)
            .navigationTitle("Match to a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
        }
        .preferredColorScheme(.dark)
    }
}

/// The short manual fallback: a date, a distance and a time. The entry's id is made once, so a retry is not stored twice.
struct ManualRunSheet: View {
    let store: InboxStore
    let onClose: () -> Void
    @State private var date = Date()
    @State private var distance = ""
    @State private var minutes = ""
    @State private var id = UUID().uuidString.lowercased()
    @State private var saving = false

    private var distanceKm: Double? { Double(distance.replacingOccurrences(of: ",", with: ".")) }
    private var durationMinutes: Double? { Double(minutes.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date).accessibilityIdentifier("manual.date")
                TextField("Distance (km)", text: $distance).keyboardType(.decimalPad).accessibilityIdentifier("manual.distance")
                TextField("Time (minutes)", text: $minutes).keyboardType(.decimalPad).accessibilityIdentifier("manual.minutes")
                if let error = store.error {
                    Text(error).foregroundStyle(Palette.accentText.color)
                }
                Button {
                    guard let km = distanceKm, let min = durationMinutes else { return }
                    saving = true
                    Task {
                        let local = LocalDay.string(from: date, in: .current)
                        if await store.addManual(id: id, localDate: local, distanceKm: km, minutes: min) { onClose() }
                        saving = false
                    }
                } label: {
                    Text("Save run").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
                }
                .disabled(distanceKm == nil || durationMinutes == nil || saving)
                .accessibilityIdentifier("manual.save")
            }
            .navigationTitle("Add a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
        }
        .preferredColorScheme(.dark)
    }
}
