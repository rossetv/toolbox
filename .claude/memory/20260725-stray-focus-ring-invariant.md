# Stray blue focus rings — the invariant that stops them recurring

The recurring "blue square" around the sidebar header, tool rows, or any plain-style
button is macOS keyboard focus, not selection. It has exactly two sources, and each has
one fixed remedy — apply the remedy at build time, never a one-off patch:

1. **Click focus.** On modern macOS a mouse click makes any focusable SwiftUI control
   (`.buttonStyle(.plain)` included) first responder, and the system draws a keyboard
   focus ring the user never asked for. **Rule: every `.buttonStyle(.plain)` control
   gets `.clearsClickFocus()`** (`DesignSystem/Components.swift`,
   `ClearsClickFocusModifier`) unless it deliberately keeps click focus. Never
   re-implement the fix with a local `@FocusState` clear — that per-control
   whack-a-mole is how the defect kept coming back.
2. **Auto-assigned focus.** Every time the main window becomes key again (sheet or
   popover closes, app reactivates), AppKit hands first responder to the FIRST focusable
   control — historically the sidebar header, hence the ring around the Toolbox logo. A
   launch-time `makeFirstResponder(nil)` is insufficient. The standing net is
   `WindowSetup.installStrayFocusClear()` (`App/WindowConfigurator.swift`): clear first
   responder on every `didBecomeKeyNotification` of the main window.

Both remedies keep Tab/arrow-key navigation rings intact (keyboard sets focus after the
click/key-transition events), per DESIGN.md's accessibility requirement.
`.focusEffectDisabled()` is the reserved third tool, only for windows outside the main
window's net where auto-focus draws a permanent ring (the About sheet, the update
banner) — it hides the ring from keyboard users too, so never reach for it first.

**Why:** this defect resurfaced repeatedly because each new focusable control or new
window-key path reintroduced it while fixes stayed local.
**How to apply:** adding any button/control → add `.clearsClickFocus()`; adding any new
window/sheet → decide focus behaviour explicitly at creation time.
