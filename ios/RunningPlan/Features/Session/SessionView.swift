import SwiftUI
import UIKit
import WorkoutKit

/// DK-Session: the spec sheet for setting the workout up on a watch. Add to Apple Watch previews the WorkoutKit workout
/// (task 4.2); Copy steps as text covers every other watch. System fonts until the font task.
struct SessionView: View {
    let model: SessionSheetModel
    var busy = false
    var error: String?
    /// The before-session feeling sent this visit, if any.
    var checkedIn: BeforeFeeling?
    /// The WorkoutKit plan for Add to Apple Watch; nil when this kind of session cannot go to the watch.
    var watchPlan: WorkoutPlan?
    var watchSync: WatchSyncModel?
    var onToggleWatchSync: () -> Void = {}
    var onBack: () -> Void = {}
    var onEdit: () -> Void = {}
    var onAdjust: (QuickAdjustment) -> Void = { _ in }
    var onSwap: () -> Void = {}
    var onCheckIn: (BeforeFeeling) -> Void = { _ in }

    @State private var ticked: Set<Int> = []
    @State private var copied = false
    @State private var previewing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                topBar
                header
                if !model.isRest { stats }
                if !model.shape.isEmpty {
                    WorkoutShape(segments: model.shape)
                        .frame(height: 64)
                        .padding(14)
                        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
                }
                Text(model.why).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Palette.muted.color)
                if !model.rows.isEmpty { steps }
                if !model.exercises.isEmpty { checklist }
                if let notes = model.notes {
                    Text(notes).font(.system(size: 15)).foregroundStyle(Palette.ink.color)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
                }
                if !model.isRest { watchButtons }
                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color)
                        .accessibilityIdentifier("session.error")
                }
                if !model.isRest && !model.isDone { adjustments }
                if !model.isRest && !model.isDone && !model.isSkipped { checkIn }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.session")
    }

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    Text(model.backLabel).font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Palette.ink.color)
                .frame(minHeight: Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to \(model.backLabel)")
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink.color)
                    .frame(width: Metrics.minTouchTarget, height: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Edit session")
            .accessibilityIdentifier("session.edit")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.eyebrow).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted.color)
                if model.isYours { badge("Yours", fill: Palette.line.color, text: Palette.yoursText.color) }
                if model.isSkipped { badge("Skipped", fill: Palette.line.color, text: Palette.muted.color) }
                if model.isDone { badge("Done", fill: Palette.green.color, text: Palette.greenInk.color) }
            }
            Text(model.title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("session.title")
        }
    }

    private func badge(_ text: String, fill: Color, text color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.vertical, 3).padding(.horizontal, 9).background(fill, in: Capsule())
    }

    private var stats: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let time = model.time { stat("Time", time) }
                if let distance = model.distance { stat("Distance", distance) }
            }
            HStack {
                Text("Effort").font(.system(size: 13)).foregroundStyle(Palette.chipText.color)
                Spacer()
                Text(model.effort).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.chipText.color)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("WATCH STEPS")
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .step(let step):
                    StepRowView(step: step).background(Palette.card.color, in: RoundedRectangle(cornerRadius: 18))
                case .repeatGroup(let count, let children):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Repeat").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                            Spacer()
                            Text("\(count)×").font(.system(size: 15, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Palette.bg.color)
                                .padding(.vertical, 4).padding(.horizontal, 12)
                                .background(Palette.ink.color, in: Capsule())
                        }
                        .padding(.horizontal, 10)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Repeat \(count) times")
                        ForEach(Array(children.enumerated()), id: \.offset) { _, step in
                            StepRowView(step: step).background(Palette.bg.color.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(10)
                    .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("EXERCISES")
            ForEach(Array(model.exercises.enumerated()), id: \.offset) { index, exercise in
                Button {
                    if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: ticked.contains(index) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(ticked.contains(index) ? Palette.green.color : Palette.muted.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                            Text(exercise.detail).font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted.color)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(ticked.contains(index) ? [.isSelected] : [])
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted.color)
            .accessibilityAddTraits(.isHeader)
    }

    private var watchButtons: some View {
        VStack(spacing: 10) {
            if let watchPlan, !model.isDone {
                Button { previewing = true } label: {
                    Label("Add to Apple Watch", systemImage: "applewatch")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Color.white)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("session.addToWatch")
                .workoutPreview(watchPlan, isPresented: $previewing)
            }
            if let watchSync, !model.isRest, watchPlan != nil || watchSync.isOn { syncRow(watchSync) }
            copyButton
        }
    }

    private func syncRow(_ sync: WatchSyncModel) -> some View {
        VStack(spacing: 2) {
            Button(action: onToggleWatchSync) {
                Text(sync.isOn ? "Stop keeping sessions on my watch" : "Keep my next sessions on my watch")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                    .frame(minHeight: Metrics.minTouchTarget)
            }
            .accessibilityIdentifier("session.watchSync")
            if let note = Self.syncNote(sync.status) {
                Text(note).font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
            }
        }
    }

    static func syncNote(_ status: WatchSyncModel.Status) -> String? {
        switch status {
        case .off: nil
        case .unsupported: "Scheduling workouts needs an iPhone paired with an Apple Watch."
        case .denied: "Allow Running Plan to schedule workouts in Settings to use this."
        case .synced(0): "Up to 15 upcoming runs stay on your watch."
        case .synced(let count): "Up to 15 upcoming runs stay on your watch. \(count) scheduled."
        }
    }

    private var copyButton: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = model.text
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy steps as text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Palette.ink.color)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.goalTrack.color, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("session.copy")
            ShareLink(item: model.text) {
                Text("Share steps").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                    .frame(minHeight: Metrics.minTouchTarget)
            }
            Text("Using a Garmin or another watch? Copy the steps and enter them in its workout builder.")
                .font(.system(size: 14)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
                .frame(maxWidth: .infinity)
        }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not feeling it today?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
            HStack(spacing: 8) {
                chip("Shorter") { onAdjust(.shorter) }
                chip("Easier") { onAdjust(.easier) }
                chip("Swap", action: onSwap)
                chip("Skip") { onAdjust(.skip) }
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)
            Text("A skipped session is never crammed in later. Any change marks the session as yours.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
        }
        .padding(18)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 22))
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Palette.ink.color)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.goalTrack.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("session.adjust.\(title.lowercased())")
    }

    private var checkIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How are you feeling right now?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.amberTitle.color)
            HStack(spacing: 8) {
                ForEach(BeforeFeeling.allCases, id: \.self) { feeling in
                    Button { onCheckIn(feeling) } label: {
                        Text(feeling.title)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(Palette.ink.color)
                            .background(checkedIn == feeling ? Palette.accentSoft.color : Palette.bg.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(checkedIn == feeling ? RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accentBorder.color, lineWidth: 2) : nil)
                            .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(checkedIn == feeling ? [.isSelected] : [])
                }
            }
            .disabled(busy || checkedIn != nil)
            Text(checkedIn == nil ? "Optional. It helps tune the next few weeks." : "Thanks, noted.")
                .font(.system(size: 14)).foregroundStyle(Palette.amberText.color)
        }
        .padding(18)
        .background(Palette.amberSoft.color, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// One watch step: a numbered circle in the step's colour, the name and target, and the goal on the right.
private struct StepRowView: View {
    let step: SessionSheetModel.StepRow

    var body: some View {
        HStack(spacing: 14) {
            Text("\(step.number)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink.color)
                .frame(width: 32, height: 32)
                .background(WorkoutShape.color(step.intensity), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Text(step.target).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            Spacer(minLength: 8)
            Text(step.value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.number), \(step.title), \(step.value), \(PaceFormat.spoken(step.target))")
    }
}
