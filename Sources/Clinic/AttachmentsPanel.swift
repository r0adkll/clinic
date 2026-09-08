import SwiftUI
import ClinicCore

/// Images the agent showed with `show_image` (ADR-056). Right column, ⌘⇧I.
struct AttachmentsPanel: View {
    @Environment(SessionStore.self) private var sessions
    let tab: Tab
    @State private var lightbox: ClinicState.Attachment?

    private var items: [ClinicState.Attachment] {
        guard let id = tab.sessionId else { return [] }
        return (sessions.state.attachments[id] ?? []).reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Attachments", systemImage: "photo.on.rectangle").font(.headline)
                Spacer()
                Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(10).background(.bar)
            Divider()
            if items.isEmpty {
                ContentUnavailableView("No images yet", systemImage: "photo", description: Text("Images the agent shows with show_image appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(items) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                if let img = NSImage(contentsOfFile: a.path) {
                                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 160)
                                        .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .onTapGesture { lightbox = a }
                                } else {
                                    Text("Missing: \(a.path)").font(.caption).foregroundStyle(.red)
                                }
                                Text(a.caption ?? (a.path as NSString).lastPathComponent).font(.caption).lineLimit(2)
                                Text(a.addedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
                                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.path, forType: .string) }
                                Button("Remove", role: .destructive) { if let id = tab.sessionId { sessions.update { s in s.attachments[id]?.removeAll { $0.id == a.id } } } }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .sheet(item: $lightbox) { a in
            VStack(spacing: 8) {
                if let img = NSImage(contentsOfFile: a.path) { Image(nsImage: img).resizable().scaledToFit() }
                HStack { Text(a.caption ?? a.path).font(.caption).lineLimit(2); Spacer(); Button("Close") { lightbox = nil }.keyboardShortcut(.cancelAction) }
            }
            .padding(12)
            .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 700)
        }
    }
}
