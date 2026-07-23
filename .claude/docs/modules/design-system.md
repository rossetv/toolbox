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
SwiftUI components built from them. Every tool view composes from this layer rather
than styling inline.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/DesignSystem/Theme.swift` | `enum Theme` — Colors, Radius, Spacing, Shadow, Typography; `Color(light:dark:)` / `NSColor(hex:)` helpers |
| `Sources/Toolbox/DesignSystem/Components.swift` | `PrimaryButton`, `LinkButton`, `Card`, `DropZone`, `StatPill`, `SegmentedPreset`(Option), `FileRow`, `ToolIconTile`, `SectionLabel`, `ToolHeader` |

## Invariants

- `Theme.Colors` values are built with `Color(light:dark:)`, which wraps an `NSColor`
  dynamic provider resolved lazily at draw time against the *current effective
  appearance* — a `static let` built once stays correct across live light/dark
  switches with no further plumbing.
- `Theme.Radius.pill` (980) is reserved for pill CTAs and compact badges; the primary
  button and rectangular containers use `card`/`input`/`control` (≤12pt) — root
  `DESIGN.md`'s Do/Don't caps rectangular corners at 12px.
- Sidebar row text takes **no explicit colour** (`SidebarView.row(for:)` — see
  [App](app.md)): the selected row's fill is drawn by AppKit, which flips the label to
  white on top of it; hard-coding `Theme.Colors.text` would leave near-black text on
  the blue selection.

## Gotchas

- **`Tool.tint`** (see [App](app.md)) gives each sidebar tool tile its own colour and is a
  **deliberate, recorded divergence** from `DESIGN.md`'s single-accent rule, not a bug to
  fix back to blue — see `.claude/DECISIONS.md`, 2026-07-23. `Theme.Colors.success` and
  `.documentBadge` already predated it as non-blue tokens.
- `Theme.Typography` line-heights are **not** reproduced per role from `DESIGN.md`:
  SwiftUI's `lineSpacing` adds to a font's natural leading rather than replacing the
  CSS line-box `DESIGN.md`'s values assume, so a naive px→points copy would be
  silently wrong. Every current consumer is single-line; multi-line tuning is
  deferred until real paragraph content exists to check it against.

## Related

- Modules: [App](app.md), [Compress](compress.md), [OCR](ocr.md)
- Human docs: root `DESIGN.md` (the law this module implements)
