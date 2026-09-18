import SwiftUI
import ClinicCore

/// What opens `CloneSheet` (ADR-168). Posted as the object of `.clinicCloneProject`.
struct CloneRequest: Identifiable {
    let id = UUID()
    /// Prefills the URL field: a dropped web address, or a smoke run's argument.
    var url = ""
    /// Asked for from the New Session sheet, where a session is the point: a finished clone goes
    /// straight to its composer instead of stopping to say it is done.
    var continueToSession = false
    /// Smoke runs only (`-ClinicCloneStartOnLaunch YES`): press Clone as soon as the sheet is up.
    var autoStart = false

    static func post(_ request: CloneRequest = CloneRequest()) {
        NotificationCenter.default.post(name: .clinicCloneProject, object: request)
    }

    /// A dropped or pasted web address that reads as a repository, for the folder drop targets.
    static func remote(in urls: [URL]) -> String? {
        urls.lazy.filter { !$0.isFileURL }.map(\.absoluteString)
            .first { if case .success = GitRemoteURL.parse($0) { true } else { false } }
    }
}

/// Add a project that is not on this Mac yet (ADR-168): paste an https or ssh URL, pick where it
/// goes, and watch `git clone` run. The clone is registered as a project when it lands. Follows the
/// New Session sheet's look (ADR-121) and Git Pull's manner (ADR-165): a refusal is said in words,
/// with git's own output one disclosure away and the next step as a button.
struct CloneSheet: View {
    let request: CloneRequest
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var parent = ""
    @State private var name = ""
    /// Once the reader types a folder name it stops following the URL.
    @State private var nameEdited = false
    @State private var phase: Phase = .form
    @State private var progress: GitCloneProgress?
    /// Only ever rises: a stage's first line can report less than the last stage's end.
    @State private var fraction: Double?
    @State private var notice: String?
    @State private var showOutput = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case url, name }

    enum Phase {
        case form
        case cloning(GitRemoteURL, URL)
        case done(GitCloneReport)
        case failed(GitCloneError, GitRemoteURL, URL)
    }

    static let directoryKey = "ClinicCloneDirectory"
    private static let width: CGFloat = 540
    private static let corner: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear(perform: prepare)
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AccentTile(symbol: "square.and.arrow.down.on.square", size: 34, glyph: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
    }

    private var title: String {
        switch phase {
        case .form: "Clone Repository"
        case .cloning(_, let dest): "Cloning \(dest.lastPathComponent)…"
        case .done(let r): "Cloned \((r.path as NSString).lastPathComponent)"
        case .failed(let e, let remote, _): Self.headline(e.failure, remote: remote)
        }
    }

    private var subtitle: String {
        switch phase {
        case .form: request.continueToSession ? "Paste a git URL. You write the prompt once it lands." : "Paste a git URL. Clinic clones it and adds it as a project."
        case .cloning(let remote, _), .failed(_, let remote, _): remote.displayName
        case .done(let r): TabFooter.abbreviate(r.path)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .form: form
        case .cloning(let remote, let dest): cloning(remote, dest)
        case .done(let r): done(r)
        case .failed(let e, let remote, _): failed(e, remote)
        }
    }

    // MARK: Form

    private var parsed: Result<GitRemoteURL, GitRemoteURL.ParseError> { GitRemoteURL.parse(urlText) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var destination: URL { URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(trimmedName, isDirectory: true).standardizedFileURL }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                field(focused: focus == .url) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("https://github.com/owner/repo or git@github.com:owner/repo.git", text: $urlText)
                        .textFieldStyle(.plain).font(.body.monospaced())
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .onSubmit(start)
                        .accessibilityLabel("Repository URL")
                }
                urlCaption
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    field(focused: false) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(TabFooter.abbreviate(parent)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Clone into \(TabFooter.abbreviate(parent))")
                        Button("Choose…") { chooseParent() }.buttonStyle(.plain).font(.callout).foregroundStyle(Color.accent)
                    }
                    Text("/").foregroundStyle(.tertiary).font(.body.monospaced())
                    field(focused: focus == .name) {
                        TextField("folder", text: Binding(get: { name }, set: { name = $0; nameEdited = !$0.isEmpty }))
                            .textFieldStyle(.plain).font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .focused($focus, equals: .name)
                            .onSubmit(start)
                            .accessibilityLabel("Folder name")
                    }
                    .frame(width: 170)
                }
                destinationCaption
            }
        }
        .onChange(of: urlText) {
            notice = nil
            if !nameEdited, case .success(let remote) = parsed { name = remote.directoryName }
        }
    }

    /// The composer card's field treatment (ADR-121): text background, hairline, accent ring while focused.
    private func field<Content: View>(focused: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(focused ? Color.accent.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
    }

    @ViewBuilder private var urlCaption: some View {
        switch parsed {
        case .success(let remote):
            caption("checkmark.circle", tint: .accent, "\(remote.displayName) over \(Self.transportName(remote.transport))")
        case .failure(.empty):
            if let notice { caption("info.circle", tint: .secondary, notice) }
            else { caption("info.circle", tint: .secondary, "An https or ssh URL. A repository’s web address works too.") }
        case .failure(let e):
            caption("exclamationmark.triangle.fill", tint: .orange, Self.explanation(e))
        }
    }

    @ViewBuilder private var destinationCaption: some View {
        if trimmedName.isEmpty {
            caption("info.circle", tint: .secondary, "The folder is named after the repository.")
        } else if !GitClone.isValidDirectoryName(name) {
            caption("exclamationmark.triangle.fill", tint: .orange, "A folder name can’t contain / or :")
        } else {
            switch GitClone.destination(at: destination) {
            case .free, .emptyDirectory:
                caption("arrow.turn.down.right", tint: .secondary, "Clones into \(TabFooter.abbreviate(destination.path))")
            case .repository:
                HStack(spacing: 6) {
                    caption("exclamationmark.triangle.fill", tint: .orange,
                            isRegistered ? "\(trimmedName) is already a project." : "\(trimmedName) is already a repository in this folder.")
                    if !isRegistered { Button("Add It Instead") { addExisting() }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accent) }
                }
            case .occupied:
                caption("exclamationmark.triangle.fill", tint: .orange, "\(trimmedName) already exists in this folder. Choose another name.")
            }
        }
    }

    private func caption(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .padding(.leading, 2)
    }

    private var isRegistered: Bool { sessions.projects.contains { $0.path == destination.path } }

    /// The remote and folder a press of Clone would use; nil while anything on the form is wrong.
    private var ready: (GitRemoteURL, URL)? {
        guard case .success(let remote) = parsed, GitClone.isValidDirectoryName(name), !parent.isEmpty else { return nil }
        switch GitClone.destination(at: destination) {
        case .free, .emptyDirectory: return (remote, destination)
        case .repository, .occupied: return nil
        }
    }

    // MARK: Cloning

    private func cloning(_ remote: GitRemoteURL, _ dest: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
            else { ProgressView().progressViewStyle(.linear) }
            HStack(spacing: 6) {
                Text(Self.stageText(progress, host: remote.host))
                Spacer(minLength: 8)
                if let detail = progress?.detail { Text(detail).monospacedDigit() }
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            caption("arrow.turn.down.right", tint: .secondary, "Into \(TabFooter.abbreviate(dest.path))")
        }
        .frame(minHeight: 60, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cloning: \(Self.stageText(progress, host: remote.host))")
    }

    // MARK: Done

    private func done(_ r: GitCloneReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine("checkmark.circle", tint: .accent,
                       r.isEmpty ? "The remote has no commits yet, so the folder is an empty repository. It’s in the sidebar now."
                                 : "It’s in the sidebar now\(r.branch.map { ", on \($0)" } ?? "").")
        }
        .frame(minHeight: 44, alignment: .top)
    }

    // MARK: Failed

    private func failed(_ e: GitCloneError, _ remote: GitRemoteURL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine("exclamationmark.triangle.fill", tint: .orange, Self.explanation(e.failure, remote: remote))
            if !e.output.isEmpty {
                DisclosureGroup("Git output", isExpanded: $showOutput) {
                    ScrollView {
                        Text(e.output).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .font(.caption)
            }
        }
    }

    private func statusLine(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            switch phase {
            case .form:
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Clone") { start() }
                    .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(ready == nil)
            case .cloning:
                Spacer()
                Button("Stop") { stop() }.keyboardShortcut(.cancelAction).controlSize(.large)
                    .help("Stop git. It removes what it had downloaded.")
            case .done(let r):
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("New Session") { dismiss(); tabs.startNewSession(projectPath: r.path) }
                    .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            case .failed(let e, let remote, let dest):
                if e.failure == .hostKey, let probe = remote.sshProbeCommand {
                    Button("Connect in a Shell") { tabs.newShell(in: parent, initialInput: probe); dismiss() }
                        .controlSize(.large)
                        .help("Runs \(probe) in a new shell, so you can accept \(remote.host)’s key")
                } else if e.failure == .authentication || e.failure == .hostKey {
                    Button("Open Shell Here") { tabs.newShell(in: parent); dismiss() }
                        .controlSize(.large)
                        .help("Open a shell in \(TabFooter.abbreviate(parent)) to sort this out")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Edit…") { phase = .form; focus = .url }.controlSize(.large)
                Button("Try Again") { clone(remote, into: dest) }
                    .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Actions

    private func prepare() {
        urlText = request.url
        parent = Self.defaultParent(projects: sessions.projects.map(\.path))
        if case .success(let remote) = parsed { name = remote.directoryName }
        focus = .url
        if request.autoStart { start() }
    }

    /// The folder last cloned into, else the one most projects already share, else `~/Developer`, else home.
    static func defaultParent(projects: [String]) -> String {
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
        }
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [String?] = [UserDefaults.standard.string(forKey: directoryKey),
                          GitClone.commonParent(of: projects.filter { !SessionStore.isChats($0) }),
                          home.appendingPathComponent("Developer").path]
        return candidates.compactMap { $0 }.first(where: isDirectory) ?? home.path
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent, isDirectory: true)
        panel.message = "Choose the folder to clone into"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }

    private func start() {
        guard case .form = phase, let (remote, dest) = ready else { return }
        clone(remote, into: dest)
    }

    private func clone(_ remote: GitRemoteURL, into dest: URL) {
        task?.cancel()
        progress = nil; fraction = nil; notice = nil; showOutput = false
        phase = .cloning(remote, dest)
        task = Task {
            let result: Result<GitCloneReport, GitCloneError>
            do throws(GitCloneError) {
                result = .success(try await GitClone.run(remote, to: dest) { p in
                    Task { @MainActor in report(p) }
                })
            } catch { result = .failure(error) }
            task = nil
            switch result {
            case .success(let r):
                UserDefaults.standard.set(parent, forKey: Self.directoryKey)
                sessions.addProject(r.path)
                if request.continueToSession {
                    dismiss()
                    tabs.startNewSession(projectPath: r.path)
                } else {
                    phase = .done(r)
                }
            case .failure(let e) where e.failure == .cancelled:
                notice = "Stopped. Nothing was left behind."
                phase = .form
            case .failure(let e):
                // Git's words are the only explanation when the reason is unrecognised.
                showOutput = e.failure == .other
                phase = .failed(e, remote, dest)
            }
        }
    }

    private func report(_ p: GitCloneProgress) {
        guard case .cloning = phase else { return }
        if let last = progress, p.stage < last.stage { return }
        progress = p
        if let f = p.fraction { fraction = max(fraction ?? 0, f) }
    }

    private func stop() { task?.cancel() }

    private func addExisting() {
        let path = destination.path
        sessions.addProject(path)
        dismiss()
        if request.continueToSession { tabs.startNewSession(projectPath: path) }
    }

    // MARK: Words

    static func transportName(_ t: GitRemoteURL.Transport) -> String {
        switch t {
        case .https: "HTTPS"
        case .http: "HTTP"
        case .ssh: "SSH"
        case .git: "the git protocol"
        }
    }

    static func explanation(_ e: GitRemoteURL.ParseError) -> String {
        switch e {
        case .empty: ""
        case .notARemote: "That doesn’t read as a git URL. Try https://host/owner/repo or git@host:owner/repo.git."
        case .unsupportedScheme("file"): "That’s a folder on this Mac. Use Add Folder for it."
        case .unsupportedScheme(let s): "Clinic clones over https and ssh, not \(s)."
        case .missingRepository: "The URL names a host but no repository."
        }
    }

    static func stageText(_ p: GitCloneProgress?, host: String) -> String {
        guard let p else { return "Connecting to \(host)…" }
        let percent = p.stageFraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        switch p.stage {
        case .connecting: return "Connecting to \(host)…"
        case .counting: return "\(host) is counting objects\(percent)"
        case .compressing: return "\(host) is compressing objects\(percent)"
        case .receiving: return "Receiving objects\(percent)"
        case .resolving: return "Resolving deltas\(percent)"
        case .checkingOut: return "Checking out files\(percent)"
        }
    }

    static func headline(_ f: GitCloneFailure, remote: GitRemoteURL) -> String {
        switch f {
        case .gitMissing: "Can’t find git"
        case .hostKey: "ssh doesn’t know \(remote.host) yet"
        case .authentication: "\(remote.host) refused access"
        case .notFound: "Couldn’t find that repository"
        case .network: "Couldn’t reach \(remote.host)"
        case .destinationExists: "The folder is already taken"
        case .noSpace: "The disk is full"
        case .cancelled: "Stopped"
        case .other: "Git clone failed"
        }
    }

    static func explanation(_ f: GitCloneFailure, remote: GitRemoteURL) -> String {
        switch f {
        case .gitMissing:
            return "Clinic looked for git on your PATH and found none. Install the command line tools with xcode-select --install, then try again."
        case .hostKey:
            return "The first connection to a host asks you to accept its key, and Clinic has no terminal to ask in. Connect once in a shell, accept the key, then try again."
        case .authentication where remote.transport == .ssh:
            return "Your SSH key wasn’t accepted. Check that it is loaded with ssh-add -l and added to your account on \(remote.host), or use the repository’s HTTPS URL."
        case .authentication:
            return "Clinic can’t answer a username or password prompt. Set up a git credential helper (gh auth setup-git does it for GitHub), or use the repository’s SSH URL."
        case .notFound:
            return "\(remote.host) has no \(remote.repositoryPath) that you can see. Check the spelling. A private repository answers the same way when you aren’t signed in."
        case .network:
            return "Check your connection or VPN, then try again."
        case .destinationExists:
            return "Something appeared in the destination folder since you chose it. Edit the folder name, then try again."
        case .noSpace:
            return "There wasn’t room for the clone. Free some space, or choose a folder on another disk."
        case .cancelled:
            return "Nothing was left behind."
        case .other:
            return "git stopped without cloning. Its output is below."
        }
    }
}
