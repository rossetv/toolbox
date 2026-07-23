<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: App

## Purpose

The shell: app entry point, the `NavigationSplitView` sidebar + detail layout, the
`Tool` enum that enumerates sidebar entries, and a headless self-test hook.

## Key files

| File | Role |
|------|------|
| `Sources/PDFToolbox/App/PDFToolboxApp.swift` | `@main` entry point; runs `CompressSmoke.runIfRequested()` before any window opens |
| `Sources/PDFToolbox/App/RootView.swift` | `NavigationSplitView` — sidebar + per-tool detail (`CompressView`/`OCRView`/placeholder) |
| `Sources/PDFToolbox/App/SidebarView.swift` | The four-entry tool list; unavailable tools rendered dimmed + disabled with a "Soon" badge |
| `Sources/PDFToolbox/App/Tool.swift` | `enum Tool` — compress/ocr/merge/split, each with title/icon/`isAvailable` |
| `Sources/PDFToolbox/App/CompressSmoke.swift` | `PDFTOOLBOX_SMOKE=compress` — runs the real compress path from the app process, exits with a pass/fail line; the CI packaged-app smoke test |

## Invariants

- `Tool.isAvailable` is the single source of truth for what's selectable — `compress`
  and `ocr` are `true`, `merge`/`split` are `false`. `RootView.detail(for:)` and
  `SidebarView` both key off it; a new "Soon" tool needs only a `Tool` case, no other
  shell change.
- `CompressSmoke` must run and exit **before** `WindowGroup` renders — it drives the
  real bundled-gs-under-sandbox path from the actual app process (xctest launches gs
  from a different context, which doesn't exercise the same `Bundle.main` resolution).

## Gotchas

- `CompressSmoke`'s synthetic fixture is generated in-process (CoreGraphics gradient +
  deterministic pseudo-random grain) into the system temp dir — never a TCC-scoped
  folder, so the headless run never blocks on a permission prompt.

## Related

- Modules: [Compress](compress.md), [OCR](ocr.md), [Services](services.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md`
