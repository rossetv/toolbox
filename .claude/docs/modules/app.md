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

The shell: app entry point, the single-pane `RootView` that mounts `QueueView`
(`Sources/Toolbox/Queue/QueueView.swift` — see [Queue](queue.md)), the
window-minimum-size and stray-focus fix-ups,
the self-update pipeline (check → user-initiated download/verify/install/relaunch),
and two headless self-test hooks (compress, update).

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/App/ToolboxApp.swift` | `@main` entry point; runs `UpdateSmoke.checkRelaunchIfMarked()` (DEBUG) then `CompressSmoke.runIfRequested()` then `UpdateSmoke.runIfRequested()` (DEBUG) then `yieldToExistingInstance()` before any window opens; declares the single `Window("Toolbox", id: "main")` and a `CommandGroup(replacing: .appInfo)` that sets `showAbout`; `AppDelegate` (`applicationWillTerminate`) empties the Rung-3 runner-up cache on quit |
| `Sources/Toolbox/App/RootView.swift` | The window's single pane: owns `QueueViewModel`, `SelfUpdater` and `UpdateChecker`, shows `UpdateBannerView` when an update is available, and constructs `QueueView(model:history:showAbout:)` — `QueueView` builds all of its own popovers/sheets directly, `RootView` only threads the model, history and the externally-owned `showAbout` binding through |
| `Sources/Toolbox/App/WindowConfigurator.swift` | `WindowSetup.applyMinimumSize(_:)` — enforces the window's minimum size (`preferredSize`, 900×640), title and titlebar style on `NSWindow`, restores/saves the remembered frame, and arms the stray-focus-clear net |
| `Sources/Toolbox/App/UpdateChecker.swift` | Fetches the latest GitHub release on launch and compares versions — the app's only unprompted network request; parses and host-pins the release page and `.dmg` asset URLs (`https`/`github.com` only), with a DEBUG-only `TOOLBOX_UPDATE_FEED` fixture-feed override |
| `Sources/Toolbox/App/SelfUpdater.swift` | The user-initiated self-update: download the release DMG (`download(_:to:session:onProgress:)`, `nonisolated static`), verify its published `.sha256`, mount it, aside-swap the running app bundle, relaunch — mirrors `scripts/install.sh` step for step; every failure leg leaves a working install on disk; sweeps abandoned `Toolbox-update-*` work directories (`sweepStaleWorkDirectories()`) before each run |
| `Sources/Toolbox/App/UpdateBannerView.swift` | The strip shown under the titlebar when `UpdateChecker.available` is set: resting state (version, "See what changed" link, Update button, per-version dismiss via `bannerDismissed` in `UserDefaults`); while an update runs, the button's slot swaps to a stage group (`activeProgress(for:)`) — a caption stage label + `CapsuleProgressBar` — driven by real download-progress fractions from `SelfUpdater.Phase.downloading(_)` |
| `Sources/Toolbox/App/AboutView.swift` | The About content: bundle icon/name/version (read from `Bundle.main.infoDictionary`, never hard-coded), GitHub/licence/contact links, copyright; presented by `QueueView` itself, driven by the `showAbout` binding |
| `Sources/Toolbox/App/CompressSmoke.swift` | `TOOLBOX_SMOKE=compress` — runs the real compress path from the app process, exits with a pass/fail line; the CI packaged-app smoke test |
| `Sources/Toolbox/App/UpdateSmoke.swift` | `TOOLBOX_SMOKE=update` (DEBUG only) — drives a real update against a `TOOLBOX_UPDATE_FEED` fixture feed and proves the relaunch actually swaps to the new bundle, via a marker file (`checkRelaunchIfMarked()`) that crosses the process boundary `open` does not carry env vars across |

## Invariants

- **`ToolboxApp.body` declares a single `Window("Toolbox", id: "main")`, not a
  `WindowGroup`**: a group hands out File ▸ New Window (⌘N), and a second window would
  construct a second `QueueViewModel` — `RunnerUpStore.sweepStale()`
  (see [Compress](compress.md)) is written to run exactly once per app run, which only
  holds because `RootView`'s `@StateObject` view models are built exactly once. `WindowSetup.applyMinimumSize`'s frame-autosave-name check (`WindowConfigurator.swift`)
  also relies on there being only ever one such window.
- **The stray-focus net is a `firstResponder` KVO watch, not a key-transition
  notification** — `WindowSetup.installStrayFocusClear(on:)` (`WindowConfigurator.swift`)
  observes the main window's `firstResponder` directly and clears any assignment whose
  current event is not `.keyDown`; a `didBecomeKeyNotification` observer misses a
  POPOVER closing (it never takes key status itself). See
  `.claude/memory/20260725-stray-focus-ring-invariant.md` for the full invariant.
- **`RootView` is a plain `VStack`** carrying the optional update banner above
  `QueueView` — there is no sidebar or per-tool detail split any more; the whole
  window is `QueueView`'s single pane.
- **`WindowSetup.applyMinimumSize` must run** (`RootView`'s `.onAppear`) because
  SwiftUI's `.frame(minWidth:minHeight:)` only constrains the *content*, not the
  window — a window opened or restored smaller than that simply clips the content.
  Setting `NSWindow.minSize` directly makes the constraint real and grows an
  already-too-small restored frame on launch.
- `CompressSmoke` must run and exit **before** the `Window` scene renders — it drives the
  real bundled-gs-under-sandbox path from the actual app process (xctest launches gs
  from a different context, which doesn't exercise the same `Bundle.main` resolution).
- **`yieldToExistingInstance()` skips under XCTest** (any `XCTest*`-prefixed env var, not
  `XCTestConfigurationFilePath` alone — a parallel-testing worker clone launches without
  that specific key) — the hosted test runner launches the app as its test host while a
  real user copy may legitimately be open; killing the host would kill the suite.
  Otherwise it finds another running process with the same bundle ID and
  `.activationPolicy == .regular` (excludes XCTest-host accessory instances),
  activates it, and calls `exit(0)` — guards against two *copies* of the bundle
  (e.g. an old build plus a fresh one) running concurrently and racing on the same
  output files, a case LaunchServices' own single-launch dedup doesn't cover.
- **`UpdateChecker` is notify-and-let-the-user-decide, not download-on-launch** — a GET to
  `api.github.com/repos/rossetv/toolbox/releases/latest`; any failure (offline,
  rate-limited, malformed) resolves to "no update". The banner's Update button is what
  triggers `SelfUpdater`'s real download/verify/install/relaunch (spec §6.10) — the
  check itself never downloads or replaces the running binary.
- **Both the release-page URL and the `.dmg` asset URL are host-pinned to `https` +
  `github.com` exactly** (`UpdateChecker.parseRelease`, `pinnedDMGURL`) — the DMG is
  self-signed, so HTTPS-to-GitHub is the only trust anchor; a hostile API response
  must not be able to redirect the user or the downloader elsewhere.
- **`SelfUpdater.download` is `nonisolated static`, never a `@MainActor` instance method** —
  a `@MainActor` `for try await byte in stream` loop paid two executor hops through the main
  thread per byte, measured at 155 KB/s against 40 MB/s off the actor, so a 16 MB DMG sat
  minutes behind a static "Downloading…" and users force-quit mid-update. It flushes in
  64 KiB chunks and calls its `onProgress: @escaping @MainActor (Double) -> Void` in order, at
  most once per whole percent of `HTTPURLResponse.expectedContentLength`, with a final `1`
  once the body is on disk — never called at all when the server declares no Content-Length
  (`total <= 0`), since a fraction against a guess would be the fabricated progress
  `Phase.downloading`'s doc forbids. `sha256(of:)` verification also runs off the main actor
  (`Task.detached`), beside the pre-existing detached install, so hashing 16+ MB never freezes
  the banner at the moment it claims to be working.
- **`sweepStaleWorkDirectories()` runs at the start of every `update(release:)`**, before
  `makeWorkDirectory()` creates this run's own directory — a force-quit mid-download skips the
  owning run's `defer`, leaking a `Toolbox-update-*` directory with a partial (~16 MB) DMG.
  Only entries older than `sweepMinimumAge` (3600s) are removed: two live instances can briefly
  coexist (the single-instance guard's tie window, DEBUG update-smoke runs), and sweeping a
  sibling's in-flight download would surface to its user as a checksum failure for a file this
  process deleted. Best-effort — a removal failure never fails the update it precedes.
- **`TOOLBOX_UPDATE_FEED` is a DEBUG-only fixture-feed override** (`UpdateChecker`'s
  `fetchLatest` init, `pinnedDMGURL`'s `feedOverrideActive`) — compiled out of every
  Release build, gated three ways when active (compile flag, override actually set,
  literal `127.0.0.1` host, never a suffix/prefix match), and exists solely so
  `UpdateSmoke` can drive the whole pipeline against a local fixture server.
- **`AppDelegate.applicationWillTerminate` calls `RunnerUpStore.removeAllOnDisk()`**
  (nonisolated static, no instance needed) — the quit-time half of Rung 3's runner-up
  cache lifecycle; `RunnerUpStore.sweepStale()` is the launch-time half. See
  [Compress](compress.md).
- **`showAbout` is owned by `ToolboxApp`, not `RootView` or `QueueView`** — the app
  menu's `CommandGroup(replacing: .appInfo)` and `QueueView`'s `⋯` menu both need to
  toggle the same presentation state, so it is threaded down as a `Binding` through
  `RootView` into `QueueView`, which owns the single `.sheet(item:)`/`.popover` surface
  it presents against.

## Gotchas

- `CompressSmoke`'s synthetic fixture is generated in-process (CoreGraphics gradient +
  deterministic pseudo-random grain) into the system temp dir — never a TCC-scoped
  folder, so the headless run never blocks on a permission prompt.
- `UpdateSmoke`'s marker file is anchored under the home directory
  (`Library/Caches/com.toolbox.app`), not `FileManager.default.temporaryDirectory`:
  the latter honours `$TMPDIR`, which the old process and the LaunchServices-relaunched
  new process are not guaranteed to agree on — both must compute the identical path for
  the marker to cross the process boundary at all.

## Related

- Modules: [Queue](queue.md), [Compress](compress.md), [OCR](ocr.md), [Services](services.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md`
