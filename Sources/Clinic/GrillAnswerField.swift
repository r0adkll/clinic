import AppKit
import SwiftUI

/// The editor a reader types their own answer into (ADR-131).
///
/// An `NSTextView` rather than a SwiftUI `TextField`, for the same reason ADR-107 put the Images pane's
/// keyboard in an `NSView`: the keys that matter here are `⇥` and `⎋`, and SwiftUI gives a text field no
/// dependable way to answer either one without also eating the typing. It is multi-line because a
/// grilling answer is often a paragraph, and `⌘⏎` still reaches the Send button, which is a window-level
/// key equivalent and so runs before `keyDown` ever gets here.
struct GrillAnswerField: NSViewRepresentable {
    @Binding var text: String
    /// True when the pane says this question is the one being answered, so `e` in Navigate mode can
    /// put the keyboard in here without the reader reaching for the pointer.
    let isActive: Bool
    /// The reader put the keyboard in here — the pane's Answering mode starts.
    let onFocus: () -> Void
    /// How the reader left: committing forward, committing backward, or abandoning the keyboard while
    /// keeping what they typed.
    let onExit: (Exit) -> Void

    enum Exit { case next, previous, cancel }

    func makeNSView(context: Context) -> NSScrollView {
        let view = GrillTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 12)
        // Set outright rather than trusted to the default: without these the box renders and takes
        // keys when focused programmatically, and ignores the mouse (ADR-138).
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.drawsBackground = false
        view.string = text
        view.onFocus = onFocus
        view.onExit = onExit

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // **The text view has to be given a size.** `NSTextView()` with no frame, handed straight to
        // `documentView`, ends up effectively zero-sized: typing still works, because a first responder
        // receives keys wherever it is, but **clicking does not — there is nothing under the pointer**.
        // That is what made the box refuse the mouse while `e` opened it perfectly well, and why a
        // reader who clicked and typed had their first letters read as shortcuts (ADR-138).
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                   height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        // Both drawn in SwiftUI instead: a border that has to change with focus cannot be
        // `NSScrollView.lineBorder` (ADR-136).
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // A scroll view that does not draw its background still has to be hit-testable, and its clip
        // view is what the pointer meets first.
        scroll.contentView.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? GrillTextView else { return }
        view.onFocus = onFocus
        view.onExit = onExit
        // Asked for, never taken: only when the pane has decided this question is being answered, and
        // only if the keyboard is not already here (making an existing first responder first again
        // resets its selection).
        if isActive, let window = view.window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        // Only when it actually differs: assigning `string` while the reader is typing would reset the
        // insertion point to the end on every keystroke.
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// The one responder for a typed answer. `⇥` and `⇧⇥` commit and move on, `⎋` hands the keyboard back
/// to the pane's Navigate mode with the draft intact — which is why cancelling is not the same as
/// clearing (ADR-131).
final class GrillTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onExit: ((GrillAnswerField.Exit) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        return ok
    }

    override func insertTab(_ sender: Any?) { onExit?(.next) }
    override func insertBacktab(_ sender: Any?) { onExit?(.previous) }
    override func cancelOperation(_ sender: Any?) { onExit?(.cancel) }
}

// MARK: - The pane's keyboard

/// Every key the Grill pane answers, named once so the pane's keymap does not have to know about
/// `NSEvent` (ADR-135).
enum GrillKey: Equatable {
    case up, down, left, right
    case tab(shift: Bool)
    case enter, space, escape
    case character(Character)
}

/// The Grill pane's first responder.
///
/// SwiftUI's `.onKeyPress` cannot carry this pane's keyboard: it delivers letters and **never** an
/// arrow key, with the handler on the scroll view or its container, generic or with the keys named
/// (measured six ways, ADR-134). The Images pane hit the same wall from the other side — a focusable
/// SwiftUI list answered ↑↓ and silently dropped ⌘C — and [[ADR-107]] settled it by giving that pane one
/// `NSView` that answers every key. This is that view for this pane.
///
/// It draws nothing and never hit-tests, so it takes no clicks; it is only ever *made* first responder,
/// which is what the earlier background-view attempt forgot to do. When the answer field takes the
/// keyboard, AppKit makes this view resign — so "who has the keyboard" has exactly one answer, held by
/// AppKit rather than inferred from SwiftUI's separate focus state.
struct GrillKeyboard: NSViewRepresentable {
    @Bindable var model: GrillPaneModel
    /// Handles a key; false lets AppKit carry on with it.
    let onKey: (GrillKey) -> Bool

    func makeNSView(context: Context) -> GrillKeyView {
        let view = GrillKeyView()
        wire(view)
        return view
    }

    func updateNSView(_ view: GrillKeyView, context: Context) {
        wire(view)
        guard model.wantsKeyboard, model.mode == .navigate else { return }
        // **One shot, next runloop turn.** Both halves matter and both were missing:
        //
        // `wantsKeyboard` used to stay true until this view *gained* focus, so every re-render
        // re-claimed the keyboard — including the re-render caused by the click that had just put it
        // in the answer field. The reader clicked the box, the pane took the keyboard straight back,
        // and their first keystrokes went to the keymap instead: `s` skipped the question being
        // answered and `e` opened the field part-way through a word (ADR-138).
        //
        // And claiming from inside `updateNSView` mutates observed state during a view update, via
        // `becomeFirstResponder`. Deferring makes the request re-checkable against what the reader has
        // done since.
        model.wantsKeyboard = false
        DispatchQueue.main.async {
            guard model.mode == .navigate, !model.wantsKeyboard,
                  let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    private func wire(_ view: GrillKeyView) {
        view.onKey = onKey
        view.onFocusChange = { has in model.hasKeyboard = has }
    }
}

final class GrillKeyView: NSView {
    var onKey: ((GrillKey) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    /// Invisible to the pointer: every click belongs to the SwiftUI controls in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let key = Self.key(for: event), onKey?(key) == true else {
            return super.keyDown(with: event)
        }
    }

    /// `⎋` arrives here rather than through `keyDown`.
    override func cancelOperation(_ sender: Any?) {
        if onKey?(.escape) != true { super.cancelOperation(sender) }
    }

    /// Flags that are not the reader pressing a modifier. **An arrow key carries `.function` and
    /// `.numericPad`**, so a guard that demands no flags at all throws every arrow away — which is
    /// exactly what this pane's keymap had been doing since ADR-131, in SwiftUI's `KeyPress.modifiers`
    /// first and then here (ADR-135).
    private static let notModifiers: NSEvent.ModifierFlags = [.shift, .function, .numericPad, .capsLock]

    private static func key(for event: NSEvent) -> GrillKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(notModifiers)
        // A chord is somebody else's — ⌘⏎ is Send, a menu equivalent that never reaches keyDown.
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 48: return .tab(shift: event.modifierFlags.contains(.shift))
        case 36, 76: return .enter
        case 49: return .space
        case 53: return .escape
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers, let first = characters.first,
              characters.count == 1 else { return nil }
        return .character(first)
    }
}

