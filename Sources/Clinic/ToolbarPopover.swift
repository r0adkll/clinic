import AppKit
import SwiftUI

/// A toolbar control in two parts — a button that acts, and a chevron that shows its choices — whose
/// choices open in a popover with a caret on the chevron, the way the notification bell's history does
/// (ADR-123). A `Menu` in the toolbar drops a free-floating NSMenu that lines up with nothing; three of
/// them beside the bell's anchored popover read as a toolbar built by two people.
struct ToolbarSplitButton<Label: View, Choices: View>: View {
    let help: String
    let choicesHelp: String
    /// `-ClinicToolbarPopoverOnLaunch <id>` opens this control's popover once the window has settled,
    /// so a smoke run can photograph it without a synthesised click (ADR-038).
    var smokeId: String?
    let action: () -> Void
    @ViewBuilder var label: Label
    @ViewBuilder var choices: Choices

    @State private var showingChoices = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(help)
            Divider().frame(height: 16)
            Button { showingChoices.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(choicesHelp)
            .popover(isPresented: $showingChoices, arrowEdge: .bottom) { choices }
        }
        .task {
            guard let smokeId, UserDefaults.standard.string(forKey: "ClinicToolbarPopoverOnLaunch") == smokeId else { return }
            try? await Task.sleep(for: .seconds(4))
            showingChoices = true
        }
    }
}

// MARK: - Menu-like popover content

/// The body of a toolbar popover: rows that look and behave like a menu's, sized to their content.
struct PopoverMenu<Content: View>: View {
    var width: CGFloat = 280
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content }
            .padding(6)
            .frame(width: width, alignment: .leading)
    }
}

/// A section's title, like a menu's section header.
struct PopoverMenuHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }
}

/// A line of explanation that is not a choice.
struct PopoverMenuNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

struct PopoverMenuDivider: View {
    var body: some View { Divider().padding(.horizontal, 8).padding(.vertical, 4) }
}

/// One choice. Highlighted with the accent under the pointer, as a menu item is; a click performs it
/// and closes the popover, as choosing from a menu does.
struct PopoverMenuRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    /// nil: no check column. Rows in a list that has checks all pass a value, so their titles line up.
    var checked: Bool? = nil
    let action: () -> Void
    @ViewBuilder var icon: Icon

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var highlighted: Bool { hovering && isEnabled }

    var body: some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 7) {
                if let checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(checked ? 1 : 0)
                        .frame(width: 12)
                }
                icon.frame(width: 16).opacity(highlighted ? 1 : 0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(0.7)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.caption).opacity(0.7).lineLimit(1)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 4 : 5)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension PopoverMenuRow where Icon == EmptyView {
    init(title: String, subtitle: String? = nil, trailing: String? = nil, checked: Bool? = nil, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, trailing: trailing, checked: checked, action: action) { EmptyView() }
    }
}
