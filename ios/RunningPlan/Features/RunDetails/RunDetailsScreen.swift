import APIClient
import SwiftUI

/// Run details (issue #131): the stored summary at once, then splits and heart-rate zones from Health when they load.
/// Opened from the all-runs list and from a session's matched run.
struct RunDetailsScreen: View {
    let inbox: InboxStore
    let plans: PlanStore
    let activityId: String
    let heart: MaxHeartRateServing?
    let onClose: () -> Void

    @State private var store: RunDetailsStore
    @State private var typedMax = ""

    init(inbox: InboxStore, plans: PlanStore, activityId: String, heart: MaxHeartRateServing?, onClose: @escaping () -> Void) {
        self.inbox = inbox
        self.plans = plans
        self.activityId = activityId
        self.heart = heart
        self.onClose = onClose
        _store = State(initialValue: RunDetailsStore(inbox: inbox, heart: heart))
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
    }

    @ViewBuilder
    private func content(_ activity: Components.Schemas.Activity) -> some View {
        let session = activity.value2.disposition == .matched
            ? activity.value2.match.flatMap { match in plans.plan?.value2.sessions.first { $0.value1.id == match.sessionId && $0.value1.deletedAt == nil }?.value2 }
            : nil
        let model = RunDetailsModel(activity: activity.value1, session: session, splitsMissing: store.splitsMissing)
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
        if let plan = model.planVsActual { planVsActual(plan) }
        splits(activity.value1)
        zones(activity.value1)
        if let note = model.limitedDataNote {
            Text(note).font(.system(size: 13)).foregroundStyle(Palette.muted.color).accessibilityIdentifier("rundetails.limited")
        }
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
