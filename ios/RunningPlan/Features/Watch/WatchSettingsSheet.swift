import SwiftUI
import UIKit

/// Watch settings: the switch for keeping the next runs on the Apple Watch, with a status line. Opened from the
/// session page and the Next card for now; Goal and settings (#77) reuses it.
struct WatchSettingsSheet: View {
    let sync: WatchSyncModel
    let plans: PlanStore
    let onClose: () -> Void

    var body: some View {
        let status = sync.status
        let line = WatchStatusCopy.settingsLine(status: status, count: sync.window.count, through: sync.window.last?.date)
        let isOn = sync.wantsSync
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { sync.wantsSync }, set: { change($0) })) {
                    Text("Keep my runs on my Apple Watch").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                }
                .tint(Palette.accent.color)
                .disabled(!sync.isSupported || sync.accountId == nil)
                .frame(minHeight: Metrics.minTouchTarget)
                .accessibilityIdentifier("watch.settings.toggle")
                .accessibilityValue(isOn ? "On" : "Off")
                Text(line.text).font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                    .accessibilityIdentifier("watch.settings.status")
                if line.offersSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .accessibilityIdentifier("watch.settings.openSettings")
                }
                Spacer()
            }
            .padding(20)
            .background(Palette.bg.color.ignoresSafeArea())
            .navigationTitle("Watch settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func change(_ on: Bool) {
        Task {
            if on {
                await sync.turnOn(sessions: plans.plan?.value2.sessions ?? [], today: PreviewViewModel.localToday())
            } else {
                await sync.turnOff()
            }
        }
    }
}
