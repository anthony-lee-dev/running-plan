import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .initial

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                PlaceholderScreen(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .tint(Palette.accentText.color)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
}
