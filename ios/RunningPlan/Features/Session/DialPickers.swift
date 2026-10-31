import SwiftUI

/// Two side-by-side wheels with a unit beside each, swiped up and down. Each wheel is a native wheel `Picker`, so
/// VoiceOver reads it as adjustable (swipe up or down to change the number).
struct TwoWheelDial: View {
    let firstLabel: String
    let firstRange: [Int]
    let firstSelection: Binding<Int>
    let firstUnit: String
    let secondLabel: String
    let secondRange: [Int]
    let secondSelection: Binding<Int>
    let secondUnit: String
    var secondFormat: (Int) -> String = { String($0) }
    var identifier: String

    var body: some View {
        HStack(spacing: 0) {
            wheel(firstLabel, firstRange, firstSelection, unit: firstUnit, format: { String($0) }, id: "\(identifier).first")
            wheel(secondLabel, secondRange, secondSelection, unit: secondUnit, format: secondFormat, id: "\(identifier).second")
        }
        .frame(height: 120)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func wheel(_ label: String, _ range: [Int], _ selection: Binding<Int>, unit: String, format: @escaping (Int) -> String, id: String) -> some View {
        HStack(spacing: 4) {
            Picker(label, selection: selection) {
                ForEach(range, id: \.self) { Text(format($0)).monospacedDigit().tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .clipped()
            Text(unit).font(.system(size: 14)).foregroundStyle(Palette.muted.color).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}
