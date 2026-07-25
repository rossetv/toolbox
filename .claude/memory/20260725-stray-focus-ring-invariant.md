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
2. **Auto-assigned focus.** On every path that is not a key press — the window becoming
   key again, a sheet closing, a POPOVER closing (which never takes key status, so
   key-transition observers miss it; that path resurrected the ring after the first
   net), app reactivation — AppKit hands first responder to the FIRST focusable control,
   historically the sidebar header. The standing net is
   `WindowSetup.installStrayFocusClear(on:)` (`App/WindowConfigurator.swift`): a KVO
   watch on the main window's `firstResponder` that clears any assignment whose current
   event is not `.keyDown`. Do NOT regress it to a `didBecomeKeyNotification` observer —
   that misses the popover path, which was proven live.

Remedy 1 leaves keyboard navigation alone entirely (it only reacts to a click). Remedy 2
enforces "only keyboard-driven focus may stand": Tab/arrow focus arrives as `.keyDown`
and survives, everything else is cleared. Known costs, accepted: focus position (never
the rings) resets on non-key paths, and a future text field focused by mouse click needs
an exemption in the net — today the main window has none. Focus RINGS still show
throughout keyboard navigation, per DESIGN.md's accessibility requirement.
`.focusEffectDisabled()` is the reserved third tool, only for windows outside the main
window's net where auto-focus draws a permanent ring (the About sheet, the update
banner) — it hides the ring from keyboard users too, so never reach for it first.

**Why:** this defect resurfaced repeatedly because each new focusable control or new
window-key path reintroduced it while fixes stayed local.
**How to apply:** adding any button/control → add `.clearsClickFocus()`; adding any new
window/sheet → decide focus behaviour explicitly at creation time.
