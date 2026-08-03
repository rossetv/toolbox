<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: DesignSystem

## Purpose

The app's design tokens (`Theme`, sourced from root `DESIGN.md`) and the reusable
SwiftUI components built from them. Every view composes from this layer rather than
styling inline; nothing here depends on `ToolJob`/`CompressPreset`/view-model state.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/DesignSystem/Theme.swift` | `enum Theme` — Colors, Radius, Spacing, Shadow, Typography, Motion; `Color(light:dark:)` / `NSColor(hex:)` and the `themeFont(_:)` text helper |
| `Sources/Toolbox/DesignSystem/Components.swift` | The app-wide primitives: `PrimaryButton`, `LinkButton`, `PDFThumbnail`, `SectionLabel`, `MotionButtonStyle` (the one press/hover style every button wears — plain rendering, `configuration.isPressed` scale, hover lift/fade, Reduce Motion gated), `ParallaxAppIcon` + `parallaxStage(_:)` (the shared pointer-tilt app icon over glow+sheen, backed by `PointerTilt`/`ParallaxStageModifier`; used by the empty state and `AboutView`), `escapeToDismiss(_:)` (backed by `EscapeResponders`, the one app-wide Escape owner) and the `clearsClickFocus()`/`pointingHandCursor()`/`continuousHover(_:)` view modifiers |
| `Sources/Toolbox/DesignSystem/QueueComponents.swift` | Everything the redesigned window is built from: `VerbChip`, `QueueRow` (+ `Emphasis`, `QueueRowSizeColumn`), `StatusIndicator`, `CapsuleProgressBar`, `CapsuleBadge`, `OptionCard`, `VariantCard`, `BatchCard`, `SecondaryButton`, `SegmentedRow`, `DropdownRow`, `ToggleRow`, `RadioRow`, `CheckRow`, `PopoverChrome` (pins its window's appearance via `NonVibrantWindowAppearance`, draws no tail — every caller now presents through a real system `.popover`), `SheetChrome`, `UpdateBannerChrome`, `QueueRowShimmer` (the active-row sweep, extracted so its `onAppear` fires when the row turns active). Its head comment carries the per-screen component map (which component each of the design's screens uses, and what is deliberately *not* a component) |

## Invariants

- `Theme.Colors` values are built with `Color(light:dark:)`, which wraps an `NSColor`
  dynamic provider resolved lazily at draw time against the *current effective
  appearance* — a `static let` built once stays correct across live light/dark
  switches with no further plumbing.
- `Theme.Radius.pill` (980) is reserved for pill CTAs and compact badges; the primary
  button and rectangular containers use `control` (8), `row` (10), `card` (12) and
  `sheet` (14) — root `DESIGN.md`'s Do/Don't caps rectangular corners at 12px, which
  every token but the redesign's sheet radius keeps. `input` (11) has no consumer left
  and is kept only as a token.
- **Every plain-rendering button (all `MotionButtonStyle` sites) gets `clearsClickFocus()`** unless it
  deliberately keeps click focus: a click on any focusable SwiftUI control makes it
  first responder and macOS then draws a keyboard focus ring the user never asked for.
  Tab/arrow navigation is untouched (it assigns focus without a click), and the modifier
  pairs with `WindowSetup`'s first-responder clear (see [App](app.md)) for the rings
  AppKit assigns with no click at all.
- **`themeFont(_:)` is the only way type is applied**, and it applies
  `.monospacedDigit()` universally — `DESIGN.md` requires every number in the UI to be
  monospaced-digit, so making it a property of the font helper rather than a per-call-site
  modifier is what stops a figure jittering as it counts.
- **`EscapeResponders` is the one owner of "Escape closes the frontmost dismissable thing"**
  (`CODE_GUIDELINES.md` §8.2): a single app-wide `NSEvent` key-down monitor over a stack of dismiss
  actions, installed on the first `escapeToDismiss(depth:_:)` registration and torn down when the
  stack empties. An explicit `EscapeDepth` (`.sheet`, `.popover`) resolves nesting — the last-
  registered popover wins, else the last-registered anything — because registration order alone
  diverges from nesting when a consent sheet arrives mid-run behind an open popover; a per-view
  monitor scoped by
  comparing `event.window` was tried and abandoned because whether an `NSPopover`'s window is the
  one a key-down is posted to is unsettled in this repo. No close button anywhere carries its own
  `.keyboardShortcut(.cancelAction)` any more — that would be a second, ambiguous Escape owner.
  **Not fully verified**: a key-code probe in this repo's UI-automation environment showed
  ordinary keys reaching a monitor of this kind while keyCode 53 never arrived from either a
  CGEvent driver or System Events — wants a check by hand.
- **`PopoverChrome`'s window is pinned to the plain (non-vibrant) appearance**
  (`NonVibrantWindowAppearance`, an `NSViewRepresentable`): a `.popover`'s host window comes up
  `NSAppearanceNameVibrantDark`/`VibrantLight` by default, and AppKit resolves native control colours
  (e.g. a `Toggle`) against that vibrancy — the visible casualty was the per-file popover's OCR
  switch compositing to near-white over the chrome's opaque surface. `Theme.Colors`' own
  `Color(light:dark:)` tokens are unaffected either way, since they already resolve down to
  `.aqua`/`.darkAqua`.

## Gotchas

- **`.plain` `buttonStyle` hit-tests only opaque label content** — padding and a
  `.background` applied *outside* the label (or outside the `Button` entirely) are
  visually present but dead to clicks. Every padded/filled `.plain` button needs an
  explicit `.contentShape(...)` covering the full visual rect placed *inside* the
  label closure — `PrimaryButton` and `SecondaryButton` both do this, the latter with
  its padding and background inside the label for the same reason. Established
  2026-07-27 after only the label text was clickable; check new `.plain` buttons
  against this pattern before shipping.
- **`QueueRow` is one shape for every screen**: `Emphasis` carries the row's tint
  (including the Problems screen's danger/warn/degraded variants) and the trailing slot
  is composed by the caller, so a ready, working, finished and problem row are the same
  component with different trailing content rather than four row types. See
  [Queue](queue.md).
- **`VariantCard` carries no `action`/`Button`** — the scan-choice cards are the one
  place in the design with neither a pointer cursor nor a hover style; `isSelected`
  drives the ring/tint only, and the choice is made by the sheet's footer buttons.
- `pointingHandCursor()` uses `.continuousHover`, not `.onHover`: a single `set()` on hover-in
  survives only until AppKit next re-evaluates its cursor rects, and any view-tree change does
  that — hovering a queue row's name used to insert the row's gear/× buttons on hover, which put
  the arrow straight back with the pointer never having left. Re-asserting per move (empirically
  traced with a cursor-inclusive `screencapture -C`) also covers a synthetic/warped pointer that
  never crosses an AppKit tracking area. Now that `QueueRow`'s gear/remove-× are always mounted
  (see [Queue](queue.md)), the specific row-name symptom is gone, but the modifier stays on
  `continuousHover` as the general fix.
- `Theme.Typography` line-heights are **not** reproduced per role from `DESIGN.md`:
  SwiftUI's `lineSpacing` adds to a font's natural leading rather than replacing the
  CSS line-box `DESIGN.md`'s values assume, so a naive px→points copy would be
  silently wrong. Multi-line tuning is deferred: the app's few wrapping strings (a card
  explanation, a reassurance line) take SwiftUI's natural leading rather than a token.

## Related

- Modules: [Queue](queue.md) (`QueueComponents.swift`'s main consumer; the app chrome
  takes `SheetChrome`/`UpdateBannerChrome` from it too), [App](app.md),
  [Compress](compress.md), [OCR](ocr.md)
- Human docs: root `DESIGN.md` (the law this module implements)
