import SwiftUI
import ClinicCore

/// Open tabs above the terminal (ADR-049). View → Show Tab Bar toggles it.
struct TabBarView: View {
    @Environment(TabStore.self) private var tabs

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs.tabs) { tab in TabChip(tab: tab, selected: tab.id == tabs.selectedTabId) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(.bar)
    }
}

struct TabChip: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.kind == .shell { Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary) } else { StateGlyph(tab: tab) }
            Text(tab.title).lineLimit(1).font(.callout)
            Button { tabs.close(tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.borderless).opacity(hovering || selected ? 1 : 0).help("Close (⌘W)")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(selected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close Tab") { tabs.close(tab) }
            if tab.sessionId != nil { Button("Toggle Terminal Panel") { tabs.togglePanel(tab) } }
        }
    }
}
