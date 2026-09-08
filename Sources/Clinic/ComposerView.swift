import SwiftUI
import UniformTypeIdentifiers
import ClinicCore

/// Multi-line prompt editor docked under a session's terminal (ADR-054). Return sends, Shift+Return inserts a newline.
struct ComposerView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let tab: Tab
    @State private var text = ""
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var canSend: Bool { tab.state == .idle && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var blockedReason: String? {
        switch tab.state {
        case .idle, nil: return nil
        case .launching: return "Waiting for Claude to start"
        case .working: return "Claude is working"
        case .waitingForPermission: return "Answer the permission prompt in the terminal first"
        case .waitingForInput: return nil
        case .exited: return "Claude exited — resume first"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 180)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropTargeted ? 2 : 1))
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if canSend { send(); return .handled }
                    return .ignored
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
            HStack(spacing: 8) {
                Text(blockedReason ?? "Return sends · Shift+Return newline · drop files or images").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Clear") { text = "" }.disabled(text.isEmpty)
                Button("Send") { send() }.keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
        .onAppear {
            if let id = tab.sessionId { text = sessions.state.sessionDrafts[id] ?? "" }
            focused = true
        }
        .onChange(of: text) { saveDraft() }
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, tab.state == .idle else { return }
        tab.surface.sendPastedLine(prompt)
        text = ""
        saveDraft()
        DispatchQueue.main.async { tab.surface.window?.makeFirstResponder(tab.surface) }
    }

    private func saveDraft() {
        guard let id = tab.sessionId else { return }
        let value = text
        sessions.update { s in if value.isEmpty { s.sessionDrafts[id] = nil } else { s.sessionDrafts[id] = value } }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in append(path: DroppedFiles.stablePath(for: url)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data, let url = DroppedFiles.save(imageData: data, ext: "png") else { return }
                    Task { @MainActor in append(path: url.path) }
                }
            }
        }
        return handled
    }

    private func append(path: String) {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        text += (text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " ") + quoted + " "
    }
}

/// Dropped images are copied into Application Support so the path Claude reads stays valid (ADR-054).
enum DroppedFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinic/dropped", isDirectory: true)
    }

    static func save(imageData: Data, ext: String) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8)).\(ext)")
        return (try? imageData.write(to: url)) != nil ? url : nil
    }

    /// Files already on disk are referenced in place, except items in volatile locations (e.g. screenshots in /tmp), which are copied.
    static func stablePath(for url: URL) -> String {
        let volatile = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]
        guard volatile.contains(where: { url.path.hasPrefix($0) }), let data = try? Data(contentsOf: url) else { return url.path }
        return save(imageData: data, ext: url.pathExtension.isEmpty ? "bin" : url.pathExtension)?.path ?? url.path
    }
}
