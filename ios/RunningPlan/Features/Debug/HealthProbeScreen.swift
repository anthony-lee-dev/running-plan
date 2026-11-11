#if DEBUG
import SwiftUI

/// Debug builds only (issue #164, slice 0): shows what Health holds for recent runs so the import can be shaped from fact.
struct HealthProbeScreen: View {
    @State private var report = "Tap Run probe."
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Reads only what the app can already read. Nothing is sent anywhere. The report has no dates, places or ids.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                    Button(running ? "Reading..." : "Run probe") { Task { await run() } }
                        .disabled(running).accessibilityIdentifier("debug.probe.run")
                    Text(report).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink.color).textSelection(.enabled)
                        .accessibilityIdentifier("debug.probe.report")
                    ShareLink(item: report) { Text("Share or copy report") }
                }
                .padding(20)
            }
            .background(Palette.bg.color)
            .navigationTitle("Health data probe")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        do { report = HealthProbeReport.text(runs: try await LiveHealthProbe().runs()) }
        catch { report = "The probe could not read Health: \(error.localizedDescription)" }
    }
}
#endif
