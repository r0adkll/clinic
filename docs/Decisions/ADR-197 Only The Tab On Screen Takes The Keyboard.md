---
status: accepted (built 2026-10-11, confirmed by the user)
date: 2026-10-11
amends: "[[ADR-139 A Round Takes The Keyboard]] (a round in a tab you are not looking at waits until you go to it), [[ADR-132 The Grill Pane Is A Wizard]] (⌘⏎ sends from anywhere *in its own tab*)"
tags: [adr, ui, panel, grill, keyboard, focus, bug]
---
# ADR-197: Only the tab on screen takes the keyboard

## Context
User (2026-10-11): *"If one session starts a grilling session and I hit cmd+enter in another session it
commits the grill session with defaults denying me choice. I've noticed odd focus issues with the grill
panel before, and if an internal notification comes in while in a new chat or other window it takes my
focus away which is jarring."*

Every live tab's content view stays mounted in its window, and only the selected one is unhidden
([[ADR-019 Window and Surface Lifetime]], [[ADR-072 Multiple Windows]]). A hidden tab's panes therefore keep
running, and three things in them acted as if they were on screen:

1. **The Grill's Send button bound ⌘⏎ unconditionally.** A SwiftUI `.keyboardShortcut` is a window-wide
   key equivalent, and a hidden `NSHostingView` still answers it. So ⌘⏎ pressed anywhere in the window —
   the New Session screen's Start, Tasks' Start, another session — could reach a background tab's round
   first and send it. Every unanswered question goes out as *"skipped, you decide"*, so the agent carries
   on with its own recommendations: the "defaults" the user saw.
2. **`TabStore.focusPanel` moved the window's first responder for any tab.** Every `showPane` ends there,
   including the ones an agent triggers with `ask_round` and `show_image`. For a background tab it made
   that tab's *hidden* terminal first responder, so the reader's typing went into a terminal they could
   not see. The check ADR-139 ran for `show_image` passed only because it was done within one tab.
3. **A round arriving made the background tab's Grill pane claim the keyboard.** `GrillKeyView` called
   `makeFirstResponder` from a hidden view, for the same reason.

The in-app notification card was not involved. It is an overlay with no focusable control. What took the
focus was the pane the same event opened in another tab.

## Decision
One question settles all three: **is this tab what its window is showing?** `TabStore.isOnScreen(tab)`
answers it — the selected tab, with no screen (a draft, Tasks, Automations…) over it.

- **`focusPanel` moves the keyboard only for a tab on screen.** It still updates occlusion and run
  ownership for any tab, since those describe the tab rather than the window.
- **The Grill's ⌘⏎ is bound only while its tab is on screen** (`keyboardShortcut(_:)` with `nil`
  otherwise). Within that tab it still sends from anywhere, as ADR-132 said.
- **A Grill keyboard request waits for its tab.** `grillKeyboardRequests` becomes a set of tab ids. The pane
  takes the keyboard and removes its id only once its tab is on screen. A round that lands in a background
  tab is therefore answered with the keyboard as soon as the reader goes there (from the notification card,
  the sidebar or a tab), instead of taking the keyboard where it is now. `GrillKeyView` also refuses to
  claim while `isHiddenOrHasHiddenAncestor`, as a backstop that does not depend on the model being right.

ADR-139's rule stands for the tab you are in: a round arriving there still takes the keyboard.

## Consequences
- An agent can no longer move the keyboard into a tab the reader is not looking at, by any pane.
- A request is not dropped when another tab makes one, as the single `Tab.ID?` was. Requests for tabs
  that close are left in the set, which is harmless.
- Switching to a tab with a waiting round gives the Grill pane the keyboard, not the terminal. This is new:
  until now, selecting a tab always put the keyboard in its terminal.
- The deeper fact stays true: hidden tabs are live views. Anything later that binds a window-wide shortcut
  or claims first responder from a pane must ask `isOnScreen` too.

## Verification
`make build` and the Clinic Dev build are clean. **Not driven live:** this session's process is not
trusted for accessibility (`AXIsProcessTrusted() == false`), so the focused element could not be read.
With the user at the machine, synthetic clicks and keys were ruled out. Clinic Dev was launched with one
session, then stopped, and its state restored.

To check by hand in Clinic Dev:
1. Two sessions, A and B. In A, ask for a grilling round, then switch to B (or open New Chat) before it
   arrives. Typing in B must stay in B, and ⌘⏎ there must not send A's round.
2. Go back to A: the Grill pane has the keyboard, so `↓` moves a question.
3. In A, with the Grill pane in front, `show_image` from B must leave A's keyboard where it was.

**Confirmed by the user** (2026-10-11), by hand in Clinic Dev: *"Okay, that worked!"*
