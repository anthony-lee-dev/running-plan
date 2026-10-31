import SwiftUI

/// Stand-in for a tab until its screen task lands (see docs/backlog.md).
struct PlaceholderScreen: View {
    let tab: AppTab

    var body: some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            Text(tab.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Palette.ink.color)
                .accessibilityIdentifier(tab.screenIdentifier)
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
