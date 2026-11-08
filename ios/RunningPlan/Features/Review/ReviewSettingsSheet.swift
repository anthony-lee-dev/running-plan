import APIClient
import Observation
import SwiftUI

/// What each review frequency means (design §6.6a), in the order the setting lists them.
enum ReviewFrequencyCopy {
    typealias Frequency = Components.Schemas.ReviewFrequency

    static let all: [Frequency] = [.weekly_plus_urgent, .weekly, .after_import, .off]

    static func title(_ frequency: Frequency) -> String {
        switch frequency {
        case .weekly: "Weekly"
        case .weekly_plus_urgent: "Weekly plus urgent"
        case .after_import: "After every import"
        case .off: "Off"
        }
    }

    static func detail(_ frequency: Frequency) -> String {
        switch frequency {
        case .weekly: "One review a week, on the day you pick. It waits on Next until you open it."
        case .weekly_plus_urgent: "As Weekly, plus a suggestion right away when you flag pain. The default."
        case .after_import: "Suggestions after each import. The weekly summary still comes on your review day."
        case .off: "No reviews and no suggestions. Pain guidance after a run always shows."
        }
    }

    /// "Last day of the week" for no chosen day.
    static func title(day: Components.Schemas.Weekday?) -> String {
        switch day {
        case nil: "Last day of the week"
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }
}

/// The review frequency and day, saved to the profile as soon as one is chosen. Reusable: Goal and settings (#77)
/// presents `ReviewSettingsSheet` too.
@MainActor
@Observable
final class ReviewSettingsModel {
    enum State: Equatable {
        case loading
        case loaded(ReviewSetting)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var saving = false
    private(set) var error: String?
    private let service: ReviewSettingsServing

    init(service: ReviewSettingsServing) {
        self.service = service
    }

    /// Forgets what was loaded (signing out or deleting the account), so the next account's settings are read afresh.
    func reset() {
        state = .loading
        error = nil
    }

    func load() async {
        do {
            state = .loaded(try await service.load())
        } catch is CancellationError {
            return
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func choose(frequency: Components.Schemas.ReviewFrequency) async {
        guard case .loaded(var setting) = state, setting.frequency != frequency else { return }
        setting.frequency = frequency
        await save(setting)
    }

    func choose(day: Components.Schemas.Weekday?) async {
        guard case .loaded(var setting) = state, setting.day != day else { return }
        setting.day = day
        await save(setting)
    }

    /// How targets are shown (Goal and settings): saved on its own, keeping the review setting as it is.
    func choose(targetDisplay: Components.Schemas.TargetDisplay) async {
        guard case .loaded(var setting) = state, setting.targetDisplay != targetDisplay else { return }
        setting.targetDisplay = targetDisplay
        await save(setting) { try await $0.saveTargetDisplay(setting) }
    }

    private func save(_ setting: ReviewSetting, using send: ((ReviewSettingsServing) async throws -> ReviewSetting)? = nil) async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let send {
                state = .loaded(try await send(service))
            } else {
                state = .loaded(try await service.save(setting))
            }
        } catch ReviewError.notPending {
            // The profile changed somewhere else: show the latest and let the user choose again.
            await load()
            error = "Your settings changed somewhere else. We've loaded the latest; choose again."
        } catch is CancellationError {
            return
        } catch {
            self.error = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ReviewError.offline: "We couldn't reach the server. Check your connection and try again."
        case ReviewError.signedOut: "You've been signed out. Sign in again to change your settings."
        default: "Something went wrong with your settings. Please try again."
        }
    }
}

/// "How often should reviews appear?": the four frequencies as choice rows and, unless Off, the review day.
struct ReviewSettingsSheet: View {
    let model: ReviewSettingsModel
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Review settings").font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.reviewSettings")
                    Spacer()
                    Button("Done", action: onClose)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                        .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                        .accessibilityIdentifier("reviewSettings.done")
                }
                switch model.state {
                case .loading:
                    ProgressView().tint(Palette.accentText.color).frame(maxWidth: .infinity).accessibilityLabel("Loading your settings")
                case .failed(let message):
                    Text(message).font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                    Button { Task { await model.load() } } label: {
                        Text("Try again").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                            .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                    }
                case .loaded(let setting):
                    Text("How often should a review appear?").font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                    ForEach(ReviewFrequencyCopy.all, id: \.self) { frequency in
                        frequencyRow(frequency, selected: setting.frequency == frequency)
                    }
                    if setting.frequency != .off { dayPicker(setting.day) }
                    if let error = model.error {
                        Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("reviewSettings.error")
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { if case .loading = model.state { await model.load() } }
    }

    private func frequencyRow(_ frequency: Components.Schemas.ReviewFrequency, selected: Bool) -> some View {
        Button { Task { await model.choose(frequency: frequency) } } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ReviewFrequencyCopy.title(frequency)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text(ReviewFrequencyCopy.detail(frequency)).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.accentText.color) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget, alignment: .leading)
            .background(selected ? Palette.accentSoft.color : Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? Palette.accentBorder.color : Palette.line.color, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .disabled(model.saving)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reviewSettings.frequency")
    }

    private func dayPicker(_ day: Components.Schemas.Weekday?) -> some View {
        let options: [Components.Schemas.Weekday?] = [nil] + Components.Schemas.Weekday.allCases.map { Optional($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Review day").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
            Picker("Review day", selection: Binding(get: { day }, set: { new in Task { await model.choose(day: new) } })) {
                ForEach(options, id: \.self) { option in Text(ReviewFrequencyCopy.title(day: option)).tag(option) }
            }
            .pickerStyle(.menu)
            .tint(Palette.accentText.color)
            .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
            .accessibilityIdentifier("reviewSettings.day")
        }
    }
}
