import APIClient
import SwiftUI

/// Run details (issue #131): the stored summary at once, then splits and heart-rate zones from Health when they load.
/// Opened from the all-runs list and from a session's matched run.
struct RunDetailsScreen: View {
    let inbox: InboxStore
    let plans: PlanStore
    let activityId: String
    let heart: MaxHeartRateServing?
    let summaries: RunSummaryServing
    let onClose: () -> Void

    @State private var store: RunDetailsStore
    @State private var summary: RunSummaryStore
    @State private var typedMax = ""
    @State private var picking = false

    init(inbox: InboxStore, plans: PlanStore, activityId: String, heart: MaxHeartRateServing?, summaries: RunSummaryServing, onClose: @escaping () -> Void) {
        self.inbox = inbox
        self.plans = plans
        self.activityId = activityId
        self.heart = heart
        self.summaries = summaries
        self.onClose = onClose
        let expects = inbox.allRuns.first { $0.value2.id == activityId }
            .map { RunDetailsStore.expectsSamples($0, healthAvailable: inbox.healthAvailable) } ?? false
        _store = State(initialValue: RunDetailsStore(inbox: inbox, heart: heart, expectsSamples: expects))
        _summary = State(initialValue: RunSummaryStore(service: summaries))
    }

    private var matchedSessionId: String? {
        inbox.allRuns.first(where: { $0.value2.id == activityId })?.value2.match?.sessionId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        Text("Back").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("rundetails.back")
                if let activity = inbox.allRuns.first(where: { $0.value2.id == activityId }) {
                    content(activity)
                } else {
                    Text("This run is no longer there.").foregroundStyle(Palette.muted.color)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .accessibilityIdentifier("screen.rundetails")
        .task { await store.open(activityId: activityId) }
        // Again after a match or unmatch: the facts and the next session depend on it.
        .task(id: matchedSessionId) {
            guard let activity = inbox.allRuns.first(where: { $0.value2.id == activityId }), RunSummaryStore.applies(to: activity) else { return }
            await summary.open(activityId: activityId, today: PreviewViewModel.localToday())
        }
        .sheet(isPresented: $picking) {
            let choices = inbox.runs(today: PreviewViewModel.localToday()).choices(for: activityId)
            SessionPicker(
                choices: choices,
                emptyNote: choices.isEmpty ? "Your plan has no open session of this type left to match it to." : nil,
                onPick: { choice in
                    picking = false
                    Task { await inbox.rematch(activityId: activityId, sessionId: choice.id, label: choice.title) }
                },
                onClose: { picking = false }
            )
        }
    }

    /// Match, Change session, Unmatch and Back to inbox, as on the all-runs list (same store calls).
    @ViewBuilder
    private func actions(sessionExists: Bool) -> some View {
        if let row = inbox.runs(today: PreviewViewModel.localToday()).rows.first(where: { $0.id == activityId }) {
            let list = RunMatchModel.actions(for: row.status, sessionExists: sessionExists)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(list, id: \.self) { action in
                        switch action {
                        case .match: SecondaryButton(title: "Match to a session") { picking = true }.accessibilityIdentifier("rundetails.match")
                        case .change: SecondaryButton(title: "Change session") { picking = true }.accessibilityIdentifier("rundetails.change")
                        case .unmatch:
                            if case .matched(let sessionId, _) = row.status {
                                SecondaryButton(title: "Unmatch") { Task { await inbox.unmatch(sessionId: sessionId) } }.accessibilityIdentifier("rundetails.unmatch")
                            }
                        case .backToInbox: SecondaryButton(title: "Back to inbox") { Task { await inbox.backToInbox(activityId) } }.accessibilityIdentifier("rundetails.inbox")
                        }
                    }
                }
                .disabled(inbox.busy)
                if let error = inbox.error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("rundetails.error")
                    SignInAgainButton(message: error)
                }
            }
        }
    }

    private var splitsSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Splits").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Palette.muted.color.opacity(0.25)).frame(height: 14)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading splits")
        .accessibilityIdentifier("rundetails.splits.loading")
    }

    @ViewBuilder
    private func content(_ activity: Components.Schemas.Activity) -> some View {
        let session = activity.value2.disposition == .matched
            ? activity.value2.match.flatMap { match in plans.plan?.value2.sessions.first { $0.value1.id == match.sessionId && $0.value1.deletedAt == nil }?.value2 }
            : nil
        let model = RunDetailsModel(activity: activity.value1, session: session, splitsMissing: store.splitsMissing, matchedSessionMissing: activity.value2.disposition == .matched && session == nil)
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 32, weight: .bold)).tracking(-0.6).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text("\(model.source) · \(model.planChip)")
                .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                .accessibilityIdentifier("rundetails.chip")
        }
        HStack(alignment: .top, spacing: 16) {
            ForEach(model.hero) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value).font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text(stat.label).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("rundetails.hero")
        if !model.grid.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(model.grid) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.value).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                        Text(stat.label).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityIdentifier("rundetails.grid")
        }
        if RunSummaryStore.applies(to: activity), let result = summary.result { RunSummaryCard(result: result) }
        if let plan = model.planVsActual { planVsActual(plan) }
        if store.loading { splitsSkeleton } else { splits(activity.value1) }
        zones(activity.value1)
        if let note = model.limitedDataNote {
            Text(note).font(.system(size: 13)).foregroundStyle(Palette.muted.color).accessibilityIdentifier("rundetails.limited")
        }
        if let weather = store.weather?.text {
            Text(weather).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                .accessibilityLabel("Weather: \(weather)")
                .accessibilityIdentifier("rundetails.weather")
        }
        actions(sessionExists: session != nil)
    }

    private func planVsActual(_ plan: CheckInModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan vs actual").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
            ForEach([plan.distance, plan.time].compactMap { $0 }, id: \.label) { bar in
                HStack {
                    Text(bar.label).foregroundStyle(Palette.muted.color)
                    Spacer()
                    Text([bar.planned, bar.actual].compactMap { $0 }.joined(separator: " → ")).monospacedDigit().foregroundStyle(Palette.ink.color)
                }
                .font(.system(size: 15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(bar.spoken)
            }
            if let pace = plan.pace {
                HStack {
                    Text("Pace").foregroundStyle(Palette.muted.color)
                    Spacer()
                    Text("\(pace.planned) → \(pace.actual)").monospacedDigit().foregroundStyle(Palette.ink.color)
                }
                .font(.system(size: 15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(pace.spoken)
                if let verdict = pace.verdict {
                    Text(verdict).font(.system(size: 14, weight: .semibold)).foregroundStyle(pace.inRange ? Palette.greenSoftText.color : Palette.accentText.color)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rundetails.plan")
    }

    @ViewBuilder
    private func splits(_ run: Components.Schemas.ActivityFields) -> some View {
        if !store.splits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Splits").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                ForEach(store.splits) { split in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(split.isPartial ? String(format: "%.1f km", split.distanceM / 1000) : "\(split.index)").foregroundStyle(Palette.muted.color)
                            Spacer()
                            if split.isFastest { Text("Fastest").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.greenSoftText.color) }
                            if split.isSlowest { Text("Slowest").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentText.color) }
                            Text("\(PaceFormat.minutesSeconds(split.paceSecPerKm))/km").monospacedDigit().foregroundStyle(Palette.ink.color)
                        }
                        .font(.system(size: 15))
                        GeometryReader { proxy in
                            Capsule().fill(split.isFastest ? Palette.greenSoftText.color : Palette.accentText.color)
                                .frame(width: max(4, proxy.size.width * split.barFraction), height: 4)
                        }
                        .frame(height: 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.spoken(split))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rundetails.splits")
        }
    }

    static func spoken(_ split: RunSplits.Split) -> String {
        let part = split.isPartial ? String(format: "Last %.1f kilometres", split.distanceM / 1000) : "Kilometre \(split.index)"
        let mark = split.isFastest ? ", fastest" : split.isSlowest ? ", slowest" : ""
        return PaceFormat.spoken("\(part), \(PaceFormat.minutesSeconds(split.paceSecPerKm))/km\(mark)")
    }

    @ViewBuilder
    private func zones(_ run: Components.Schemas.ActivityFields) -> some View {
        switch store.zones {
        case .hidden:
            EmptyView()
        case .askForMax:
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart-rate zones").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Text("Tell us your maximum heart rate to see time in each zone. We never guess it, and you only enter it once.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                TextField("Max heart rate (bpm)", text: $typedMax)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .background(Palette.bg.color, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("rundetails.maxhr")
                HStack(spacing: 10) {
                    SecondaryButton(title: "Save") { Task { await store.saveMax(Int(typedMax) ?? 0, durationSec: run.durationSec) } }
                        .accessibilityIdentifier("rundetails.maxhr.save")
                    SecondaryButton(title: "Not now") { store.decline(durationSec: run.durationSec) }
                        .accessibilityIdentifier("rundetails.maxhr.decline")
                }
                .disabled(store.saving)
                if let error = store.error { Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .contain)
        case .zones(let zones):
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart-rate zones").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                ForEach(zones) { zone in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Zone \(zone.zone)").foregroundStyle(Palette.muted.color)
                            Spacer()
                            Text("\(InboxModel.duration(Int(zone.seconds.rounded()))) · \(Int((zone.share * 100).rounded()))%").monospacedDigit().foregroundStyle(Palette.ink.color)
                        }
                        .font(.system(size: 15))
                        GeometryReader { proxy in
                            Capsule().fill(Palette.accentText.color).frame(width: max(zone.share > 0 ? 4 : 0, proxy.size.width * zone.share), height: 4)
                        }
                        .frame(height: 4)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rundetails.zones")
        }
    }
}
