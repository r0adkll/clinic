import SwiftUI
import ClinicCore

/// Open tabs above the terminal (ADR-049). View → Show Tab Bar toggles it.
struct TabBarView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(WindowState.self) private var window
    @Environment(KeyBindings.self) private var bindings

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs(in: window)) { tab in TabChip(tab: tab, selected: tab.id == window.selectedTabId) }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
            // The panel's show/hide and zoom live here, always available whatever the panel holds
            // (ADR-079, ADR-081): both act on the panel rather than on anything inside it.
            if let tab = tabs.selectedTab(in: window), !tab.isReplay {
                Divider().frame(height: 18)
                Button { tabs.togglePanelZoom(tab) } label: {
                    Image(systemName: tab.panel.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(tab.panel.isZoomed ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 8)
                .help(tab.panel.isZoomed ? "Shrink the panel back beside the session" + bindings.hint(.zoomPanel)
                                         : "Expand the panel to fill the window" + bindings.hint(.zoomPanel))
                Button { tabs.togglePanelVisibility(tab) } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(tab.panel.isVisible ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .help(tab.panel.isVisible ? "Hide the panel" + bindings.hint(.togglePanelVisibility) + ", or ⇧-click its tab bar"
                                          : "Show the panel" + bindings.hint(.togglePanelVisibility))
            }
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
            if tab.kind == .shell { Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary) }
            else if tab.isReplay { Image(systemName: "play.circle").font(.caption).foregroundStyle(.secondary) }
            else if tab.isAttached { Image(systemName: "moon.zzz.fill").font(.caption).foregroundStyle(.secondary) }
            else { StateGlyph(tab: tab) }
            Text(tab.title).lineLimit(1).font(.callout)
            Button { tabs.close(tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.borderless).opacity(hovering || selected ? 1 : 0).help("Close (⌘W), or ⇧-click the tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(selected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        // ⇧-click closes the tab (ADR-130). It goes through `close`, not around it, so a running
        // session still asks before its child is killed (ADR-037) — the modifier is a shortcut to
        // the ✕, not a way past what the ✕ would have asked.
        .onTapGesture { if NSEvent.modifierFlags.contains(.shift) { tabs.close(tab) } else { tabs.select(tab) } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close Tab") { tabs.close(tab) }
            if tab.sessionId != nil { Button("Terminal in Panel") { tabs.togglePanel(tab) } }
            Divider()
            MoveToWindowMenu(tab: tab)
        }
    }
}
