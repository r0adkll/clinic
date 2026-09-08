import SwiftUI
import ClinicCore

/// Sheet target for "Generate Icon…" (ADR-076).
struct IconGenerationTarget: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Draws a project icon with headless `claude -p`, previews it, and writes `.clinic/icon.svg` on Use (ADR-076).
struct GenerateIconSheet: View {
    let target: IconGenerationTarget
    @Environment(\.dismiss) private var dismiss
    @State private var hint = ""
    @State private var svg: String?
    @State private var image: NSImage?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var running: Bool { task != nil }
    private var current: NSImage? { ProjectIconCache.shared.image(for: target.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Generate Icon").font(.title3.weight(.semibold))
                Text("Claude reads \(target.name)'s README and manifests, then draws an SVG. Nothing is written until you press Use; the icon is saved as `.clinic/icon.svg` inside the project.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            TextField("Style hint (optional)", text: $hint, prompt: Text("flat, dark blue, a caduceus"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { generate() }
                .disabled(running)

            preview

            HStack {
                Button(running ? "Generating…" : (svg == nil ? "Generate" : "Regenerate")) { generate() }
                    .disabled(running)
                if running { Button("Stop") { cancel() } }
                Spacer()
                Button("Cancel") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use") { use() }.keyboardShortcut(.defaultAction).disabled(image == nil || running)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { task?.cancel() }
        // `-ClinicGenerateIconAutorun generate|use`: press Generate (and then Use) for the smoke test (ADR-038).
        .task {
            switch UserDefaults.standard.string(forKey: "ClinicGenerateIconAutorun") {
            case "use": generate(autoUse: true)
            case .some(let v) where !v.isEmpty: generate()
            default: break
            }
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quinary)
            if running {
                VStack(spacing: 8) { ProgressView(); Text("claude is drawing…").font(.caption).foregroundStyle(.secondary) }
            } else if let error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineLimit(4).textSelection(.enabled).padding(.horizontal, 12)
                }
            } else if let image {
                HStack(spacing: 20) {
                    chip(image, background: .white, label: "Light")
                    chip(image, background: Color(white: 0.13), label: "Dark")
                    if let current {
                        Divider().frame(height: 60)
                        VStack(spacing: 6) {
                            Image(nsImage: current).resizable().interpolation(.high).scaledToFit().frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text("Current").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No icon yet. Press Generate.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
    }

    /// The two sizes that matter: the sidebar's 22 pt and something big enough to judge.
    private func chip(_ image: NSImage, background: Color, label: String) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func generate(autoUse: Bool = false) {
        guard !running else { return }
        error = nil
        let hint = hint
        task = Task {
            do {
                let result = try await ProjectIconGenerator.generate(projectPath: target.path, hint: hint)
                svg = result
                image = NSImage(data: Data(result.utf8))
                if image == nil { svg = nil; error = "The generated SVG could not be rendered. Try again." }
            } catch let failure as ProjectIconGenerator.Failure {
                if failure != .cancelled { error = failure.message }
            } catch {
                self.error = error.localizedDescription
            }
            task = nil
            if autoUse && image != nil { use() }
        }
    }

    private func cancel() { task?.cancel(); task = nil }

    private func use() {
        guard let svg else { return }
        do {
            try ProjectIconGenerator.save(svg, projectPath: target.path)
            ProjectIconCache.shared.invalidate(target.path)
            dismiss()
        } catch {
            self.error = "Could not write .clinic/icon.svg: \(error.localizedDescription)"
        }
    }
}
