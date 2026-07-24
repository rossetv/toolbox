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

The shell: app entry point, the sidebar + detail layout, the `Tool` enum that
enumerates sidebar entries (only tools that actually exist — no placeholders), the
window-minimum-size fix-up, and a headless self-test hook.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/App/ToolboxApp.swift` | `@main` entry point; runs `CompressSmoke.runIfRequested()` then `yieldToExistingInstance()` before any window opens; `AppDelegate` (`applicationWillTerminate`) empties the Rung-3 runner-up cache on quit |
| `Sources/Toolbox/App/UpdateChecker.swift` | Notify-only GitHub Releases version check on launch — the app's only network request; never downloads or self-replaces |
| `Sources/Toolbox/App/RootView.swift` | An explicit `HStack`/`VStack` split — update banner, sidebar + per-tool detail (`CompressView`/`OCRView`) |
| `Sources/Toolbox/App/SidebarView.swift` | One collapsible-rail entry per built `Tool`, each a coloured tile (`Tool.tint`) plus its name; header uses `NSApp.applicationIconImage` for the real bundle icon; a bottom info button opens `AboutView` as a sheet |
| `Sources/Toolbox/App/AboutView.swift` | The About sheet: bundle icon/name/version (read from `Bundle.main.infoDictionary`, never hard-coded), GitHub/licence/contact links, copyright |
| `Sources/Toolbox/App/Tool.swift` | `enum Tool` — `compress`/`ocr`, each with `title`/`systemImage`/`tint` |
| `Sources/Toolbox/App/WindowConfigurator.swift` | `WindowSetup.applyMinimumSize(_:)` — enforces the window's minimum size, title and titlebar style directly on `NSWindow` |
| `Sources/Toolbox/App/CompressSmoke.swift` | `TOOLBOX_SMOKE=compress` — runs the real compress path from the app process, exits with a pass/fail line; the CI packaged-app smoke test |

## Invariants

- **`RootView` is a plain `HStack`, not `NavigationSplitView`**: that container laid
  the sidebar out a titlebar's height too high (drawing over the traffic lights, the
  first entries scrolled out of view) and, on a slightly-too-small window, collapsed
  the sidebar to zero width — how the app first shipped looking as though it had no
  sidebar at all.
- **`WindowSetup.applyMinimumSize` must run** (`RootView`'s `.onAppear`) because
  SwiftUI's `.frame(minWidth:minHeight:)` only constrains the *content*, not the
  window — a window opened or restored smaller than that simply clips the content,
  with the sidebar as the casualty. Setting `NSWindow.minSize` directly makes the
  constraint real and grows an already-too-small restored frame on launch.
- **`Tool` lists only built tools** — `compress`/`ocr` are the only cases; the spec's
  dimmed "Soon" `merge`/`split` placeholders were removed on the maintainer's
  instruction (`.claude/DECISIONS.md`, 2026-07-23). Adding a tool means adding a case,
  no `isAvailable`/disabled-state plumbing exists any more.
- **`Tool.tint` gives each sidebar tile its own colour** — a deliberate divergence
  from `DESIGN.md`'s single-accent rule, recorded in `.claude/DECISIONS.md`
  (2026-07-23); not something to "fix" without the design doc's owner amending it.
- `CompressSmoke` must run and exit **before** `WindowGroup` renders — it drives the
  real bundled-gs-under-sandbox path from the actual app process (xctest launches gs
  from a different context, which doesn't exercise the same `Bundle.main` resolution).
- **`yieldToExistingInstance()` skips under XCTest** (`XCTestConfigurationFilePath` env
  var check) — the hosted test runner launches the app as its test host while a real
  user copy may legitimately be open; killing the host would kill the suite. Otherwise
  it finds another running process with the same bundle ID, activates it, and calls
  `exit(0)` — guards against two *copies* of the bundle (e.g. an old build plus a fresh
  one) running concurrently and racing on the same output files, a case LaunchServices'
  own single-launch dedup doesn't cover.
- **`UpdateChecker` is the app's only network request** — a GET to
  `api.github.com/repos/rossetv/toolbox/releases/latest`, notify-only: any failure
  (offline, rate-limited, malformed) resolves to "no update", and the banner's button
  only opens the release page in the browser — the app never downloads or replaces its
  own binary.
- **`AppDelegate.applicationWillTerminate` calls `RunnerUpStore.removeAllOnDisk()`**
  (nonisolated static, no instance needed) — the quit-time half of Rung 3's runner-up
  cache lifecycle; `RunnerUpStore.sweepStale()` is the launch-time half. See
  [Compress](compress.md).

## Gotchas

- `CompressSmoke`'s synthetic fixture is generated in-process (CoreGraphics gradient +
  deterministic pseudo-random grain) into the system temp dir — never a TCC-scoped
  folder, so the headless run never blocks on a permission prompt.

## Related

- Modules: [Compress](compress.md), [OCR](ocr.md), [Services](services.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md`
