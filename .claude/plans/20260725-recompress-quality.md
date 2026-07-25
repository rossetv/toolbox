# Recompress at a Different Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Spec:** `.claude/specs/20260725-recompress-quality.md` (approved) · **Branch:** `feat/recompress-quality`

## Goal

Make the already-visible quality selector the recovery path after a batch finishes: selecting a
different preset *arms* the finished rows with a visible prediction, one button press recompresses
them from the original input, and the version the user had is parked so a single click brings it
back. Nothing persists past quit.

## Architecture

A new view-model-owned `VersionStore` becomes the single display authority for a row's versions
(shipped + up to two parked), replacing the scattered `switched` / `jobPresets` / `batchAlternates`
bookkeeping and the byte counts frozen inside `JobOutcome`. Arming is **derived**, never stored — a
pure function of (selected preset, the row's recorded versions, the row's futile records) — so
re-selecting the original preset disarms instantly with no state to unwind. Execution bypasses
`ToolQueue` entirely (it destroys delivered state) and calls `CompressEngine` directly per job,
committing through a park-and-promote protocol in `RunnerUpStore` so the previous version survives
every failure.

## Tech Stack

- Swift 5, SwiftUI, Combine, AppKit/QuickLook/PDFKit (existing app targets only)
- XCTest, hosted `ToolboxTests` bundle, driven through `CompressViewModel` (no UI harness)
- XcodeGen (`project.yml`, glob source discovery — new files need no project edit)

## Global Constraints

- **macOS 14+** — `deploymentTarget.macOS: "14.0"` in `project.yml`; no newer API.
- **SwiftUI** for all UI; components come from `Sources/Toolbox/DesignSystem` and `Theme` tokens.
- **No new dependencies** — system frameworks only.
- **AGPL SPDX header** on every new file, copied verbatim from an existing source file.
- **British English** in all prose (comments, docs, commit messages). Code identifiers follow the
  NEAREST SIBLING in the same file, not the prose rule: `Components.swift` already spells it
  `StatPill.Tone.color` (and `Theme.Shadow.color`), while `MRCSegmenter.swift` has a local
  `colour` and `CompressPreset.swift` a `colourDPI` — each file is consistent with itself, and a
  new member matches whatever its file already does.
- **Output naming per v1 §5.4** — `FileNaming.output` never overwrites; every delivery is an atomic
  move onto a guaranteed-absent path.
- **Session-only cache** — parked versions live under `RunnerUpStore`'s root: swept at launch,
  wiped at quit, discarded on row removal / "Clear finished" / slot replacement. Nothing new is
  persisted.
- **`ToolQueue` is behaviour-preserving for OCR** — this plan does **not** modify
  `Sources/Toolbox/Shared/ToolQueue.swift` at all (R19). OCR's `resultURL ?? url` open fallback and
  `.alreadySearchable` handling are untouched.
- **Done means the gates in `.claude/GATES.md` are green — all SEVEN of them.** Never weaken a test,
  a script, or the gate file to make one pass. The full set, and what this plan does about each:

  | Gate | Kind | This plan |
  |------|------|-----------|
  | `ghostscript-builds` | mechanical | **Unaffected** — no task touches `scripts/build-ghostscript.sh`, the pinned source digest, or anything under `Resources/ghostscript/`. Not re-run; nothing in the diff can change its result. |
  | `ghostscript-self-contained` | mechanical | **Unaffected** — same reason: the bundled `gs` binary and its link set are outside every task's file list. |
  | `project-generates` | mechanical | **Covered, not unaffected** — no task edits `project.yml` (sources are glob-discovered), but Task 13 runs `xcodegen generate` anyway, because a new file that the glob does not pick up would be invisible until the build failed. |
  | `builds` | mechanical | **Run** — Tasks 4, 5, 6 and 12 each end on a build, and Task 13 runs it as the gate. |
  | `tests` | mechanical (`mandated-by-human: yes` — edited 2026-07-24 by human override, see `DECISIONS.md`) | **Run** — Task 13 runs it in its gate form verbatim, 8-way parallel. Its human mandate is why no task may narrow it. |
  | `packaged-app-compresses` | mechanical | **Run** — Task 13, copied verbatim from `GATES.md` (single line, own trap and mount parsing). |
  | `no-personal-corpus-references` | semantic | **Run** — Task 13 asserts it over the branch diff. Every fixture in this plan is synthetic and generated in-process. |

## Track plan

Type definitions are landed **before** any fork, because a worktree-isolated track cannot compile
against a sibling's unmerged symbols. Only one fork is genuinely disjoint; everything else is
serial, because `CompressViewModel.swift` and `CompressView.swift` are consumed by every step.

| Phase | Track | Tasks | Exact file set |
|-------|-------|-------|----------------|
| 1 — foundation | **serial** | 1–4 | `Compress/VersionStore.swift`, `Compress/RunnerUpStore.swift`, `Compress/CompressEstimator.swift`, `Compress/CompressViewModel.swift`, `Shared/FileNaming.swift`, `Compress/HeavyCompressionPopover.swift` (type + body swap, pre-rename), `Compress/CompressView.swift` (accessor rename plus the one `status(for:)` byte read), `Tests/ToolboxTests/{VersionStoreTests,RunnerUpStoreTests,EstimatorTests,CompressViewModelTests}.swift` |
| 2 — fork | **Track P** (presentation) | 5–6 | `Compress/VersionsPopover.swift` (renamed from `HeavyCompressionPopover.swift`), `DesignSystem/Components.swift`, **and** the one `HeavyCompressionPopover` call site in `Compress/CompressView.swift` |
| 2 — fork | **Track E** (engine/model) | 7–10 | `Compress/CompressViewModel.swift`, `Tests/ToolboxTests/CompressViewModelTests.swift` — **never** `CompressView.swift` |
| 3 — integration | **serial** | 11–13 | `Compress/CompressViewModel.swift` (Task 11), `Compress/CompressView.swift` (Task 12), `Tests/ToolboxTests/CompressViewModelTests.swift` (Tasks 11 and 12), the mockup HTML (Task 12), then the gates |

Track P and Track E are parallel-eligible: their file sets are disjoint, and every type Track P
consumes (`FileVersion`, `RowVersions`, `EngineVariant`, `VersionSlot`) is defined in Phase 1, so
neither compiles against the other's unmerged work. Tasks *inside* a track are sequential.

Round 1's fixes changed **no FORK file set** — Track P's and Track E's sets are exactly as first
stated (Phase 3's serial set did grow: Task 12 gained
`Tests/ToolboxTests/CompressViewModelTests.swift`, which the row above now lists). Every fix that
touched presentation stayed inside
`Components.swift` (Track P) and every fix that touched behaviour stayed inside
`CompressViewModel.swift` + `CompressViewModelTests.swift` (Track E). The disjointness above holds
exactly as originally stated. This is deliberate, not luck — where a finding needed both an
assertable rule and a rendering change, the rule went onto the model (testable from
`CompressViewModelTests`) and only the one-line consumption went into the view, which is Phase 3's
serial file anyway.

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `Sources/Toolbox/Compress/VersionStore.swift` | **Create** | `EngineVariant`, `FileVersion`, `VersionSlot`, `RowVersions`, `VersionStore` — the row-versions display authority, the only path that discards a parked file, and the owner of `reservePreviousURL` (which forwards to `cache.reserveURL(for:suffix:reserving:)`). |
| `Sources/Toolbox/Compress/RunnerUpStore.swift` | Modify | Widens `reserveURL` with a `suffix:` parameter (default preserves every current call site) and adds the R12 `promote(fresh:to:parking:)` commit primitive beside the existing `switchVersions`. |
| `Sources/Toolbox/Compress/CompressEstimator.swift` | Modify | `estimateAll` becomes `analyse`, returning `Analysis` (content type + per-preset estimates) so R16 can decide whether the engine path repeats. |
| `Sources/Toolbox/Compress/CompressViewModel.swift` | Modify | Owns the store, the derived arming state, the R16 prediction, the two-phase run, the R12 commit and every aggregate the view reads. |
| `Sources/Toolbox/Compress/HeavyCompressionPopover.swift` → `VersionsPopover.swift` | **Rename + modify** | 2 cards at 340 pt / 3 cards at 470 pt, preset+variant labels, per-card preview and "Use this". |
| `Sources/Toolbox/DesignSystem/Components.swift` | Modify | `FileRow.Lead` (armed pill / futile pill / instant-switch link / error note), `FileRow.metaAccent`, `SuccessBanner.tone`. |
| `Sources/Toolbox/Compress/CompressView.swift` | Modify | Armed row rendering, armed banner + footer copy, run-scoped progress, disable rules, the R17 aggregator sweep. |
| `Tests/ToolboxTests/VersionStoreTests.swift` | **Create** | Store bookkeeping, slot replacement discarding the superseded file, prune-discards-files. |
| `Tests/ToolboxTests/RunnerUpStoreTests.swift` | Modify | Commit-protocol tests for `promote`. |
| `Tests/ToolboxTests/CompressViewModelTests.swift` | Modify | Arming, prediction, commit, cancel, pinning, mixed-run counts (R20). |
| `Tests/ToolboxTests/EstimatorTests.swift` | Modify | Call-site update for `analyse` + a content-type assertion. |
| `.claude/specs/20260725-recompress-quality-evidence/recompress-ux-mockup.html` | Modify | One-line correction where the mockup contradicts R10 (Task 12). |

## Copy rules (bind every task)

Preset names come from `CompressPreset.title` — **"High quality"**, **"Balanced"**, **"Smallest"**.
The mockup's "Maximum quality" / "Smallest size" are stale; the code is the authority. Never
hard-code a preset name in a format string; always interpolate `preset.title`.

---

# Phase 1 — serial foundation (Tasks 1–4)

Nothing forks until every type below exists on the branch. Task order is the topological order of
the definitions: `RunnerUpStore` primitives → `VersionStore` types → estimator analysis → view-model
adoption.

### Task 1: RunnerUpStore commit primitives

**Model:** opus · **Track:** serial (Phase 1)

**Files**
- Modify: `Sources/Toolbox/Compress/RunnerUpStore.swift`
- Modify: `Sources/Toolbox/Shared/FileNaming.swift`
- Test: `Tests/ToolboxTests/RunnerUpStoreTests.swift`

**Interfaces**
- Consumes: `RunnerUpStore.SwitchError` (existing), `FileNaming.output(for:suffix:folder:reserving:)`
- Produces:
  - `func reserveURL(for input: URL, suffix: String = "runner-up", reserving reserved: inout Set<String>) -> URL`
  - `func promote(fresh: URL, to shipped: URL, parking parked: URL) throws`
  - `static func FileNaming.reservationKey(for url: URL) -> String` (widened from `private`)

**Steps**

- [ ] Write the failing tests in `Tests/ToolboxTests/RunnerUpStoreTests.swift`, appended before the
      closing brace:

```swift
    // MARK: R12 commit protocol (recompress)

    /// The commit: the previously shipped file ends up in the cache slot `parking` names and the
    /// fresh result takes its place. Every move lands, and neither the temp path nor the
    /// beside-the-shipped-file dot-temp is left behind.
    func testPromoteParksTheShippedFileAndLandsTheFreshOne() throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        // The shipped file lives where the USER's output lives, not in the cache root — the whole
        // point of the three-step shape is that the two are different places.
        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")
        let parked = root.appendingPathComponent("shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)
        try Data("new-version".utf8).write(to: fresh)

        try store.promote(fresh: fresh, to: shipped, parking: parked)

        XCTAssertEqual(try Data(contentsOf: shipped), Data("new-version".utf8))
        XCTAssertEqual(try Data(contentsOf: parked), Data("old-version".utf8),
                       "the version the user had must reach the cache slot it was reserved, not "
                     + "merely survive somewhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        // The intermediate dot-temp is a transient, not a resting place: nothing named
        // `.toolbox-*` may survive beside the delivered file.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty, "the dot-temp must not outlive the commit: \(leftovers)")
    }

    /// The third step is best-effort by design: if the parked version cannot reach its cache slot
    /// the commit still SUCCEEDS (the user has their new file) and the old version is discarded
    /// rather than stranded under a hidden dot-name nothing will ever look for.
    func testPromoteSucceedsAndDiscardsWhenTheParkSlotIsUnreachable() throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")
        // A park path inside a directory that does not exist: the move to the cache slot cannot
        // succeed, deterministically.
        let parked = root.appendingPathComponent("absent-dir/shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)
        try Data("new-version".utf8).write(to: fresh)

        XCTAssertNoThrow(try store.promote(fresh: fresh, to: shipped, parking: parked))

        XCTAssertEqual(try Data(contentsOf: shipped), Data("new-version".utf8),
                       "the promotion is what the user pressed the button for; it stands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty, "a park that cannot land is discarded, never stranded")
    }

    /// R12's load-bearing guarantee: the old version survives any failure. An absent `fresh` makes
    /// the promote move fail deterministically, after the shipped file has already been parked.
    func testPromoteFailureRestoresTheShippedFile() throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")   // never written
        let parked = root.appendingPathComponent("shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)

        XCTAssertThrowsError(try store.promote(fresh: fresh, to: shipped, parking: parked)) { error in
            XCTAssertFalse(error is RunnerUpStore.SwitchError,
                           "the restore succeeded, so the promote's own error must surface")
        }
        XCTAssertEqual(try Data(contentsOf: shipped), Data("old-version".utf8),
                       "a failed commit must put the user's file back untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path),
                       "the park slot must not keep a copy after the restore")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty,
                      "the dot-temp must be emptied by the restore: \(leftovers)")
    }

    /// Parked previous versions and runner-ups share the cache root, so they must not collide: the
    /// suffix is what keeps a row's two parked files apart under the same serial allocator.
    func testReserveURLHonoursTheRequestedSuffix() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)
        let input = root.appendingPathComponent("scan.pdf")

        var reserved = Set<String>()
        let runnerUp = store.reserveURL(for: input, reserving: &reserved)
        let previous = store.reserveURL(for: input, suffix: "previous", reserving: &reserved)

        XCTAssertEqual(runnerUp.lastPathComponent, "scan-runner-up.pdf")
        XCTAssertEqual(previous.lastPathComponent, "scan-previous.pdf")
    }
```

- [ ] Run them and watch them fail (the first two do not compile — `promote` does not exist yet;
      that IS the failure):

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/RunnerUpStoreTests
```

- [ ] Implement in `Sources/Toolbox/Compress/RunnerUpStore.swift`. Change the existing
      `reserveURL` signature to carry a suffix (default preserves every current call site):

```swift
    /// Reserve a cache URL for one of a job's parked versions, via the same serial allocator as
    /// every batch output (C4). `suffix` keeps a row's runner-up and its parked previous version
    /// (R14) apart in the shared cache root. Call in the view-model's up-front reservation loop.
    func reserveURL(for input: URL, suffix: String = "runner-up",
                    reserving reserved: inout Set<String>) -> URL {
        FileNaming.output(for: input, suffix: suffix, folder: root, reserving: &reserved)
    }
```

      and add, directly beneath `switchVersions`:

```swift
    /// The R12 recompress commit: park the currently-shipped file, promote `fresh` into its place,
    /// then move the parked version into the cache slot `parked` names.
    ///
    /// **Three steps, exactly as `switchVersions` does it, and for the same reason.** The version
    /// the user currently has is parked into a `.toolbox-<uuid>` dot-temp **beside the shipped
    /// file** — never straight into `parked`, which lives in the cache root. Two reasons, both
    /// load-bearing: the cache root is swept at launch, so a crash in this window with the user's
    /// only delivered copy sitting in it would destroy that copy; and the cache root is frequently
    /// on a different volume from the output folder, where `moveItem` silently degrades to a
    /// copy-then-delete and the "atomic" park is no longer atomic. The dot-temp idiom matches the
    /// engine's, so a crash leftover is the already-accepted residual pattern.
    ///
    /// Failure shapes, in the order the steps run:
    /// 1. **Park fails** — nothing has moved; an ordinary throw, shipped file untouched.
    /// 2. **Promote fails** — the park is undone by the same documented restore `switchVersions`
    ///    uses, then the promote's own error is rethrown. If even the restore fails,
    ///    `SwitchError.shippedStranded` carries the dot-temp path, because the user's file is no
    ///    longer where they left it and nothing else will ever look for it there.
    /// 3. **Reaching the cache slot fails** — the commit has ALREADY succeeded from the user's
    ///    point of view (their file holds the new version), so this **does not throw**: the parked
    ///    copy is discarded instead of being stranded under a hidden dot-name. The caller therefore
    ///    must not assume a file exists at `parked` after a successful return — see `commit` in the
    ///    view model, and `useVersion`'s already-designed-for "that version is no longer available"
    ///    path (a `previous` slot whose file is gone is an existing, handled state, not a new one).
    ///
    /// The old version therefore survives every path on which the promotion did NOT happen, which
    /// is what lets an armed row keep its result when a recompress fails.
    func promote(fresh: URL, to shipped: URL, parking parked: URL) throws {
        let fm = FileManager.default
        let temp = shipped.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-promote-\(UUID().uuidString).pdf")
        try fm.moveItem(at: shipped, to: temp)            // 1. park beside the shipped file
        do {
            try fm.moveItem(at: fresh, to: shipped)       // 2. promote the fresh result
        } catch {
            // Restore on the documented path for each state, exactly as `switchVersions` does:
            // `shipped` is normally absent here, so a plain `moveItem` restores it; if something
            // recreated it in this window, `replaceItemAt` swaps that impostor out.
            do {
                if fm.fileExists(atPath: shipped.path) {
                    _ = try fm.replaceItemAt(shipped, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: shipped)
                }
            } catch {
                throw SwitchError.shippedStranded(parked: temp)
            }
            throw error
        }
        do {
            try fm.moveItem(at: temp, to: parked)         // 3. into the cache slot
        } catch {
            // Best effort, deliberately: see step 3 above. Discard rather than strand.
            try? fm.removeItem(at: temp)
        }
    }
```

- [ ] Widen `FileNaming.reservationKey(for:)` from `private static` to `static` (body and doc
      comment unchanged), adding one sentence to its doc: *"Internal rather than private so a caller
      holding a path it did not allocate — an existing result being recompressed — can seed it into
      the same reservation set (R11)."* Duplicating the key's case/normalisation rules at a call
      site is exactly the rot this avoids.
- [ ] Run the same command; all `RunnerUpStoreTests` pass (the pre-existing ones included).
- [ ] Commit: `feat(compress): add the recompress commit primitive to the runner-up store`

---

### Task 2: Version store and its types

**Model:** opus · **Track:** serial (Phase 1)

**Files**
- Create: `Sources/Toolbox/Compress/VersionStore.swift`
- Test: `Tests/ToolboxTests/VersionStoreTests.swift` (create)

**Interfaces**
- Consumes: `RunnerUpStore.reserveURL(for:suffix:reserving:)`, `RunnerUpStore.discard(_:)`,
  `CompressPreset`, `ToolJob.ID`
- Produces: `EngineVariant`, `FileVersion`, `VersionSlot`, `RowVersions`, `VersionStore` (all
  top-level, so Phase-2 Track P compiles against them without Track E's work)

**Steps**

- [ ] Write the failing tests in a new `Tests/ToolboxTests/VersionStoreTests.swift`:

```swift
// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// `VersionStore` is the display authority for a row's versions (R14) and the ONLY path that
/// discards a parked file — a slot dropped without its file discarded is exactly the growing
/// cache D6 forbids.
@MainActor
final class VersionStoreTests: XCTestCase {

    private func makeStore() throws -> (VersionStore, RunnerUpStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = RunnerUpStore(rootOverride: root)
        return (VersionStore(cache: cache), cache, root)
    }

    private func file(_ root: URL, _ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A second recompress replaces the previous slot and discards the file the old one held —
    /// at replacement time, not at quit (R14: "no cache leak").
    func testReplacingThePreviousSlotDiscardsTheSupersededFile() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let firstPrevious = try file(root, "out-previous.pdf", bytes: 300)
        let secondPrevious = try file(root, "out-previous-1.pdf", bytes: 200)

        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .plain),
                                 runnerUp: nil,
                                 previous: FileVersion(url: firstPrevious, bytes: 300,
                                                       preset: .maximumQuality, variant: .plain)),
                     for: id)

        store.setSlot(.previous, to: FileVersion(url: secondPrevious, bytes: 200,
                                                 preset: .balanced, variant: .plain), for: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPrevious.path),
                       "the superseded previous version's file must be discarded at replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPrevious.path))
        XCTAssertEqual(store.versions(for: id)?.previous?.bytes, 200)
    }

    /// Dropping a row discards its parked files but never the user's delivered output.
    func testDiscardRowRemovesParkedFilesAndKeepsTheShippedFile() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        let previous = try file(root, "out-previous.pdf", bytes: 300)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: FileVersion(url: previous, bytes: 300,
                                                       preset: .maximumQuality, variant: .plain)),
                     for: id)

        store.discardRow(id)

        XCTAssertNil(store.versions(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shipped.path),
                      "the delivered output is the user's file and is never discarded")
    }

    /// Pruning to the live rows must DISCARD, not merely forget: a filtered dictionary leaks every
    /// parked file of every row that left the queue.
    func testRetainDiscardsTheFilesOfDroppedRows() throws {
        let (store, _, root) = try makeStore()
        let live = UUID(), dropped = UUID()
        let liveRunnerUp = try file(root, "live-runner-up.pdf", bytes: 10)
        let droppedRunnerUp = try file(root, "dropped-runner-up.pdf", bytes: 10)
        for (id, runnerUp) in [(live, liveRunnerUp), (dropped, droppedRunnerUp)] {
            store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                     shipped: nil,
                                     runnerUp: FileVersion(url: runnerUp, bytes: 10,
                                                           preset: .balanced, variant: .plain),
                                     previous: nil),
                         for: id)
        }

        store.retain(only: [live])

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveRunnerUp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: droppedRunnerUp.path))
        XCTAssertNil(store.versions(for: dropped))
    }

    /// The switch exchanges the two files' CONTENTS in place, so the URLs stay put and only the
    /// descriptions move between the slots — the invariant every byte badge reads.
    func testSwapMovesDescriptionsBetweenSlotsAndLeavesURLsInPlace() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let previous = try file(root, "out-previous.pdf", bytes: 300)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .smallestSize,
                                 shipped: FileVersion(url: shipped, bytes: 100,
                                                      preset: .smallestSize, variant: .mrc),
                                 runnerUp: nil,
                                 previous: FileVersion(url: previous, bytes: 300,
                                                       preset: .balanced, variant: .plain)),
                     for: id)

        store.swapShipped(with: .previous, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.shipped?.url, shipped, "the delivered path never moves")
        XCTAssertEqual(row.shipped?.bytes, 300)
        XCTAssertEqual(row.shipped?.preset, .balanced)
        XCTAssertEqual(row.previous?.url, previous)
        XCTAssertEqual(row.previous?.bytes, 100)
        XCTAssertEqual(row.previous?.preset, .smallestSize)
        XCTAssertEqual(row.rowPreset, .balanced, "the row's preset follows the shipped version")
    }

    /// R15's capsule vocabulary: today's dynamic family survives while only the runner-up is
    /// parked, and the title becomes "Versions" once a previous version exists.
    func testCapsuleTitleKeepsTodaysFamilyUntilAPreviousVersionExists() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: nil),
                     for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Heavy compression")

        store.swapShipped(with: .runnerUp, for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Normal compression")

        store.setSlot(.previous, to: FileVersion(url: try file(root, "p.pdf", bytes: 5), bytes: 5,
                                                 preset: .maximumQuality, variant: .plain), for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Versions")
        XCTAssertEqual(store.versions(for: id)?.count, 3)
    }
}
```

- [ ] Run them and watch them fail to compile (`VersionStore` does not exist):

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/VersionStoreTests
```

- [ ] Create `Sources/Toolbox/Compress/VersionStore.swift` with the AGPL header and:

```swift
import Foundation

/// Which engine leg produced a version. `.plain` covers every non-MRC engine result — the
/// Ghostscript output and the Rung-2 CCITT rebuild alike — because the only distinction the
/// estimate calibration needs (R16) is whether the MRC leg shipped this version.
enum EngineVariant: Equatable {
    case mrc
    case plain
    /// The untouched input, parked when the gs leg bloated and there was nothing legitimate to
    /// offer as an alternative (R6/R7).
    case original
}

/// One version of a row's file. The preset lives HERE, not on the job: a later batch at a
/// different preset must never rewrite a finished row's preset (R14).
struct FileVersion: Equatable {
    let url: URL
    let bytes: Int
    let preset: CompressPreset
    let variant: EngineVariant
}

/// The two parked slots a row can hold. The shipped version has no slot — it is the user's
/// delivered file and is never discarded.
enum VersionSlot: Equatable {
    /// This run's engine runner-up (the heavy/gs race's loser).
    case runnerUp
    /// The ONE previous version a recompress parked (D3).
    case previous
}

/// Every version a row knows about, plus the original size every aggregate is measured against.
struct RowVersions: Equatable {
    /// The input's size — the `before` behind every badge, pill and banner total.
    let originalBytes: Int
    /// The preset of the row's most recent COMPLETED attempt (a shipped result or a no-gain). A
    /// FAILED attempt never records here, so a transient failure stays retryable at the same
    /// preset rather than silently disarming the row (R1).
    var lastAttemptPreset: CompressPreset
    /// The user-visible file. Absent on a row that has shipped nothing (a no-gain row).
    var shipped: FileVersion?
    var runnerUp: FileVersion?
    var previous: FileVersion?

    /// The row's preset (R1): the shipped version's where one exists, else the last attempt's.
    var rowPreset: CompressPreset { shipped?.preset ?? lastAttemptPreset }

    /// The popover's cards, in order: current, this run's alternative, the previous version. The
    /// current card carries no slot — there is nothing to switch to from itself.
    var cards: [(slot: VersionSlot?, version: FileVersion)] {
        var out: [(slot: VersionSlot?, version: FileVersion)] = []
        if let shipped { out.append((nil, shipped)) }
        if let runnerUp { out.append((.runnerUp, runnerUp)) }
        if let previous { out.append((.previous, previous)) }
        return out
    }

    var count: Int { cards.count }

    /// The row's capsule label (R15). Today's dynamic family is preserved while the runner-up is
    /// the only parked version — a switched row keeps its honest label — and the title becomes
    /// "Versions" as soon as a previous version joins it.
    var capsuleTitle: String {
        if previous != nil { return "Versions" }
        switch shipped?.variant {
        case .mrc: return "Heavy compression"
        case .original: return "Original"
        default: return "Normal compression"
        }
    }
}

/// The display authority for every row's versions (R14), and the only path that discards a parked
/// file. Replacing or dropping a slot discards the file it held at that moment — never at quit —
/// so the session cache cannot grow with superseded versions (D6/R18).
/// @MainActor: owned and driven by `CompressViewModel`.
@MainActor
final class VersionStore {
    private let cache: RunnerUpStore
    private var rows: [ToolJob.ID: RowVersions] = [:]

    init(cache: RunnerUpStore) {
        self.cache = cache
    }

    func versions(for id: ToolJob.ID) -> RowVersions? { rows[id] }

    /// Record a completed attempt's versions wholesale (the batch-ingest path). Any parked file the
    /// old entry held and the new one does not is discarded here.
    func record(_ versions: RowVersions, for id: ToolJob.ID) {
        let superseded = Self.parkedURLs(of: rows[id]).subtracting(Self.parkedURLs(of: versions))
        rows[id] = versions
        for url in superseded { cache.discard(url) }
    }

    /// Replace one parked slot, discarding the file the old occupant held (R14).
    func setSlot(_ slot: VersionSlot, to version: FileVersion?, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        let old = slot == .runnerUp ? row.runnerUp : row.previous
        switch slot {
        case .runnerUp: row.runnerUp = version
        case .previous: row.previous = version
        }
        rows[id] = row
        if let old, old.url != version?.url { cache.discard(old.url) }
    }

    /// Land a committed recompress: the new shipped version, and the preset it was produced at.
    func setShipped(_ version: FileVersion, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.shipped = version
        row.lastAttemptPreset = version.preset
        rows[id] = row
    }

    /// Record a completed attempt that shipped nothing (a no-gain recompress), so the row's preset
    /// follows its most recent attempt (R1).
    func recordAttempt(_ preset: CompressPreset, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.lastAttemptPreset = preset
        rows[id] = row
    }

    /// The switch: `RunnerUpStore` exchanges the two files' CONTENTS in place, so the URLs stay
    /// exactly where they are and only the descriptions move between the slots.
    func swapShipped(with slot: VersionSlot, for id: ToolJob.ID) {
        guard var row = rows[id], let shipped = row.shipped else { return }
        guard let parked = slot == .runnerUp ? row.runnerUp : row.previous else { return }
        row.shipped = FileVersion(url: shipped.url, bytes: parked.bytes,
                                  preset: parked.preset, variant: parked.variant)
        let demoted = FileVersion(url: parked.url, bytes: shipped.bytes,
                                  preset: shipped.preset, variant: shipped.variant)
        switch slot {
        case .runnerUp: row.runnerUp = demoted
        case .previous: row.previous = demoted
        }
        rows[id] = row
    }

    /// Drop a row, discarding every parked file it held. The shipped file is the user's delivered
    /// output and is never touched.
    func discardRow(_ id: ToolJob.ID) {
        for url in Self.parkedURLs(of: rows[id]) { cache.discard(url) }
        rows[id] = nil
    }

    /// Prune to the live rows. The ONLY removal path alongside `discardRow`: filtering the
    /// dictionary without discarding the files would leak every parked version of every row that
    /// left the queue.
    func retain(only liveIDs: Set<ToolJob.ID>) {
        for id in Array(rows.keys) where !liveIDs.contains(id) { discardRow(id) }
    }

    /// Reserve the cache name a parked previous version will take, through the same serial
    /// allocator as every batch output (R11).
    func reservePreviousURL(for input: URL, reserving reserved: inout Set<String>) -> URL {
        cache.reserveURL(for: input, suffix: "previous", reserving: &reserved)
    }

    private static func parkedURLs(of row: RowVersions?) -> Set<URL> {
        Set([row?.runnerUp?.url, row?.previous?.url].compactMap { $0 })
    }
}
```

- [ ] Run the same command; all five tests pass.
- [ ] Commit: `feat(compress): add the row version store behind the recompress flow`

---

### Task 3: Expose the estimator's content classification

**Model:** sonnet · **Track:** serial (Phase 1)

R16 must decide whether the engine path repeats, which needs the row's classification
(`wantsMRC = classification == .scanColour && preset != .maximumQuality`). The estimator already
classifies the document and throws the answer away.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressEstimator.swift`
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift` (call site only)
- Test: `Tests/ToolboxTests/EstimatorTests.swift`

**Interfaces**
- Consumes: `PDFContentType`, `SizeEstimate`, `CompressPreset`
- Produces:
  - `struct CompressEstimator.Analysis { let contentType: PDFContentType?; let estimates: [CompressPreset: SizeEstimate] }`
  - `func analyse(_ input: URL) async -> Analysis` (replaces `estimateAll(_:)`)

**Steps**

- [ ] Write the failing test, appended to `Tests/ToolboxTests/EstimatorTests.swift` before its
      closing brace:

```swift
    /// The recompress prediction (R16) can only tell whether the engine path repeats if it knows
    /// the row's classification, so a successful analysis must surface it alongside the estimates.
    func testAnalysisSurfacesTheContentTypeAlongsideTheEstimates() async throws {
        let estimator = CompressEstimator()
        let input = try Fixtures.bornDigitalPDF()

        let analysis = await estimator.analyse(input)

        XCTAssertEqual(analysis.contentType, .bornDigital)
        XCTAssertEqual(analysis.estimates.count, CompressPreset.allCases.count)
    }

    /// A failed or timed-out analysis has no classification to offer, and says so rather than
    /// guessing — the prediction then falls back to the raw estimate.
    func testAnalysisReportsNoContentTypeWhenAnalysisFails() async throws {
        let estimator = CompressEstimator()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).pdf")

        let analysis = await estimator.analyse(missing)

        XCTAssertNil(analysis.contentType)
        XCTAssertTrue(analysis.estimates[.balanced]?.isFallback == true)
    }
```

- [ ] Run and watch it fail:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/EstimatorTests
```

- [ ] Implement in `CompressEstimator`: rename `estimateAll(_:)` to `analyse(_:)` and return the
      new type.

```swift
    /// A single analysis pass's result: the per-preset predictions, and the classification they
    /// were derived from. The classification is nil when the analysis failed or overran its time
    /// box — the estimates are then the typical-range fallback, and any caller that reasons about
    /// the engine path (R16) must not assume one.
    struct Analysis {
        let contentType: PDFContentType?
        let estimates: [CompressPreset: SizeEstimate]
    }

    func estimate(_ input: URL, preset: CompressPreset) async -> SizeEstimate {
        await analyse(input).estimates[preset] ?? Self.fallbackEstimate(
            inputSize: Self.fileSize(input), preset: preset)
    }

    /// Predictions for EVERY preset, from a single analysis pass. (Doc comment otherwise unchanged.)
    func analyse(_ input: URL) async -> Analysis {
        let inputSize = Self.fileSize(input)
        let analyser = self.analyser
        let measured = await Self.timeBoxed(seconds: timeBudget) {
            try? Self.measure(input, inputSize: inputSize, analyser: analyser)
        }
        var out: [CompressPreset: SizeEstimate] = [:]
        for preset in CompressPreset.allCases {
            if let measured {
                out[preset] = Self.predict(measured, inputSize: inputSize, preset: preset)
            } else {
                out[preset] = Self.fallbackEstimate(inputSize: inputSize, preset: preset)
            }
        }
        return Analysis(contentType: measured?.contentType, estimates: out)
    }
```

- [ ] Update the two remaining call sites: `EstimatorTests`'s concurrency test
      (`_ = await estimator.estimateAll(input)` → `_ = await estimator.analyse(input)`), and
      `CompressViewModel.scheduleEstimate`, whose stored state becomes the whole analysis:

```swift
    /// Per-job analysis — every preset's prediction plus the classification behind them, computed
    /// once, so changing preset is a lookup and the recompress prediction (R16) can tell whether
    /// the engine path repeats.
    private var analyses: [UUID: CompressEstimator.Analysis] = [:]
```

      with `scheduleEstimate` storing `self.analyses[job.id] = await self.estimator.analyse(job.url)`,
      `publishJobs` reading `display.estimate = analyses[job.id]?.estimates[preset]`, and
      `pruneStaleEstimateState` filtering `analyses` where it filtered `estimates`.

- [ ] Run the estimator suite and the view-model suite; both green:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/EstimatorTests -only-testing:ToolboxTests/CompressViewModelTests
```

- [ ] Commit: `refactor(compress): surface the estimator's classification alongside its estimates`

---

### Task 4: The view model adopts the version store as display authority

**Model:** opus · **Track:** serial (Phase 1)

The riskiest task in the plan: it retires three pieces of scattered bookkeeping and rewires every
existing display path onto the store, with **no behaviour change**. The existing
`CompressViewModelTests` are the safety net.

> **Binding constraint — do not weaken the net.** Ten existing tests call
> `model.heavyVersions(for:)` and `model.displayedSizes(for:)`
> (`testCompressedHeavyOutcomePublishesHeavyVersions`,
> `testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize`, `testSwitchTogglesInstantlyAndReversibly`,
> `testCapsuleTitleFlipsOnSwitch`, `testCapsuleTitleReadsOriginalWhenRunnerUpIsInput`,
> `testSavedBytesUsesShippedVersionForHeavyJob`, `testDisplayedBytesTracksShippedVersion`,
> `testSwitchWithMissingRunnerUpRerunsJob`, `testSwitchFailingAfterRerunLeavesStateCanonical`,
> `testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling`).
> Rename the CALL SITES only; every
> assertion is preserved **verbatim**, including the intrinsic byte counts
> (`HeavyEnv.heavyBytes`/`normalBytes` never move on a switch), the exact capsule strings
> ("Heavy compression" / "Normal compression" / "Original"), `displayedSizes` returning nil for a
> failed-switch row, and `testLaterBatchDoesNotRewriteAFinishedRowsPreset`'s
> `XCTAssertEqual(env.stub.presets.last, .smallestSize)`. A rewritten assertion reads as a
> weakened gate and will be sent back.
>
> The constraint binds the ASSERTIONS, not the setup around them. One test's setup does change
> later: Task 10's `compress()` arms finished rows, which breaks
> `testLaterBatchDoesNotRewriteAFinishedRowsPreset`'s second batch, so that task moves the test's
> preset change to after the batch — intent, assertion and message all verbatim. Nothing changes in
> THIS task, where the test still passes exactly as written.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Modify: `Sources/Toolbox/Compress/HeavyCompressionPopover.swift`
- Modify: `Sources/Toolbox/Compress/CompressView.swift` (accessor rename plus the one `status(for:)` byte read)
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `VersionStore`, `RowVersions`, `FileVersion`, `EngineVariant`, `VersionSlot`,
  `RunnerUpStore.reserveURL(for:suffix:reserving:)`
- Produces:
  - `func versions(for job: ToolJob) -> RowVersions?` (replaces `heavyVersions(for:)`; the nested
    `HeavyVersions` struct is deleted)
  - `func displayedSizes(for job: ToolJob) -> (before: Int, after: Int)?` (unchanged signature,
    re-derived from the store)
  - `func useVersion(_ slot: VersionSlot, for job: ToolJob)` and
    `func switchVersion(for job: ToolJob)` (the runner-up shorthand the existing tests drive)

**Steps**

- [ ] Rename the call sites in `Tests/ToolboxTests/CompressViewModelTests.swift`. The COMPLETE
      mapping — every member `HeavyVersions` exposes, so nothing is discovered mid-task:

      | `HeavyVersions` member | `RowVersions` replacement |
      |---|---|
      | `model.heavyVersions(for:)` | `model.versions(for:)` |
      | `versions.shippedIsHeavy` | `(versions.shipped?.variant == .mrc)` |
      | `versions.heavyBytes` | `versions.cards.first(where: { $0.version.variant == .mrc })?.version.bytes` |
      | `versions.normalBytes` | `versions.cards.first(where: { $0.version.variant != .mrc })?.version.bytes` |
      | `versions.displayedBytes` | `versions.shipped?.bytes` |
      | `versions.runnerUpIsOriginal` | `(versions.runnerUp?.variant == .original)` |
      | `versions.shippedURL` | `versions.shipped?.url` |
      | `versions.runnerUpURL` | `versions.runnerUp?.url` |
      | `versions.capsuleTitle` | `versions.capsuleTitle` (unchanged — `RowVersions` carries it) |

      Adjust only the accessor, never the expected value. Add `try XCTUnwrap` where an accessor
      became optional — the byte, URL and variant accessors all did; `capsuleTitle` did not.

      SIX test DOC COMMENTS also name members this task deletes and would survive a
      call-sites-only rename, leaving the file documenting symbols that no longer exist. All six
      are rewritten in this step; the wording is otherwise untouched.

      | Doc comment above | Names | Becomes |
      |---|---|---|
      | `testCompressedHeavyOutcomePublishesHeavyVersions` | "surfaces both versions through `heavyVersions(for:)`" | `versions(for:)` |
      | `testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize` | "`heavyVersions(for:)` must mark it so the popover labels that card 'Original'" | `versions(for:)` |
      | `testSwitchTogglesInstantlyAndReversibly` | "flips `shippedIsHeavy`" | "flips which version is shipped" |
      | `testDisplayedBytesTracksShippedVersion` | "`displayedBytes` drives the row's size badge/percent" | "the shipped version's byte count drives the row's size badge/percent" |
      | `testCapsuleTitleFlipsOnSwitch` | "it must flip with `shippedIsHeavy` and … matching `HeavyCompressionPopover.normalTitle`'s \"Normal\"" | "it must flip with the shipped version and … matching the label `VersionsPopover.label(_:slot:)` gives the parked card, \"Normal\"" |
      | `testCapsuleTitleReadsOriginalWhenRunnerUpIsInput` | "matching the popover's `normalTitle`" | "matching the label `VersionsPopover.label(_:slot:)` gives that card" |

      The last two are a CONTENT coupling across the track fork: `normalTitle` is a member of
      `HeavyCompressionPopover.swift`, the file Track P's Task 6 renames to `VersionsPopover.swift`
      and rewrites. Both citations are therefore reworded to the SURVIVING vocabulary —
      `VersionsPopover.label(_:slot:)` — in this task, so no later track has to reach back into
      `CompressViewModelTests.swift` (Track E's file) to repair a dead citation.
- [ ] Run the suite and watch it fail to compile (`versions(for:)` does not exist yet):

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/CompressViewModelTests
```

- [ ] In `CompressViewModel`, build the store in `init` beside the cache and delete the retired
      state (`switched`, `jobPresets`, `batchAlternates` and the `HeavyVersions` struct):

```swift
    private let store: RunnerUpStore
    /// The display authority for every row's versions (R14). Owns the preset each version was
    /// produced at, so a later batch can never rewrite a finished row's preset, and it is the only
    /// path that discards a parked file.
    private let versionStore: VersionStore
    /// The preset each in-flight queue job was dispatched at, consumed once when the job's outcome
    /// is ingested into the store. Not display state — the store owns that.
    private var pendingPresets: [ToolJob.ID: CompressPreset] = [:]
    /// Runner-up cache names reserved for the in-flight batch. A run-scoped RESERVATION ledger, not
    /// a version record: a reservation whose job never shipped a runner-up is discarded by `cancel`
    /// and by the run's own teardown, and everything committed is owned by `versionStore`.
    private var runReservations: [ToolJob.ID: URL] = [:]
```

      with `self.versionStore = VersionStore(cache: store)` after `store.sweepStale()`.

- [ ] Ingest completed queue jobs into the store from the `queue.$jobs` sink, BEFORE `publishJobs()`:

```swift
    /// Move every newly-finished queue job's result into the version store — the one place a
    /// queue-driven outcome becomes display state. `pendingPresets` is consumed here, so this is
    /// idempotent across the many republishes a single batch produces.
    private func ingestCompletedJobs() {
        for job in rawJobs {
            guard case .done(let outcome) = job.state,
                  let preset = pendingPresets[job.id] else { continue }
            pendingPresets[job.id] = nil
            switch outcome {
            case .compressed(let before, let after):
                guard let url = job.resultURL else { continue }
                versionStore.record(RowVersions(originalBytes: before, lastAttemptPreset: preset,
                                                shipped: FileVersion(url: url, bytes: after,
                                                                     preset: preset, variant: .plain),
                                                runnerUp: nil, previous: nil),
                                    for: job.id)
            case .compressedHeavy(let before, let after, let runnerUpBytes):
                guard let url = job.resultURL, let alternate = job.alternateURL else { continue }
                // The engine parks a gs runner-up only when it is strictly smaller than the input,
                // so equality is the unambiguous "the original was parked instead" marker (R6/R7).
                versionStore.record(RowVersions(originalBytes: before, lastAttemptPreset: preset,
                                                shipped: FileVersion(url: url, bytes: after,
                                                                     preset: preset, variant: .mrc),
                                                runnerUp: FileVersion(url: alternate,
                                                                      bytes: runnerUpBytes,
                                                                      preset: preset,
                                                                      variant: runnerUpBytes == before
                                                                          ? .original : .plain),
                                                previous: nil),
                                    for: job.id)
            case .noGain(let bytes):
                // Nothing shipped, but the attempt still fixes the row's preset (R1). A wholesale
                // `record` is safe here: only `.queued` rows ever reach this path, and a row
                // holding a previous version is `.done` and can never re-enter the queue.
                versionStore.record(RowVersions(originalBytes: bytes, lastAttemptPreset: preset,
                                                shipped: nil, runnerUp: nil, previous: nil),
                                    for: job.id)
            case .ocrAdded, .alreadySearchable:
                continue        // never produced by CompressEngine
            }
        }
    }
```

- [ ] In `compress()`, record `pendingPresets[job.id] = chosen` where `jobPresets` was set (same
      `isStillQueued(job)` guard, same reason — an already-finished row must not be reattributed),
      and `runReservations = alternates`.
- [ ] Replace `heavyVersions(for:)` with the store-backed accessor, and re-derive `displayedSizes`:

```swift
    /// The versions available for `job`, or nil when the row has none to show. A row whose switch
    /// could not be honoured stops advertising versions it can no longer back (the F6 mislabel).
    func versions(for job: ToolJob) -> RowVersions? {
        guard switchFailures[job.id] == nil else { return nil }
        return versionStore.versions(for: job.id)
    }

    /// The before/after byte pair `job` contributes to the batch totals, or nil when the row has
    /// shipped nothing (queued/running/failed/no-gain/OCR). `after` is always the SHIPPED version's
    /// size, so a switch or a recompress keeps the totals in step with the row's own badge.
    func displayedSizes(for job: ToolJob) -> (before: Int, after: Int)? {
        guard let row = versions(for: job), let shipped = row.shipped else { return nil }
        return (row.originalBytes, shipped.bytes)
    }
```

- [ ] Generalise the switch to any slot, keeping the binary shorthand the popover and the existing
      tests call:

```swift
    /// Per-row messages that must NOT replace the row's result — the row keeps its result and its
    /// versions and carries the message beside them. Distinct from `switchFailures`, which puts the
    /// row into `.failed` precisely because that row can no longer back what it was claiming.
    @Published private(set) var recompressErrors: [ToolJob.ID: String] = [:]

    /// The popover's switch, and its "Use this" per card. Instant when the parked file still
    /// exists; if the RUNNER-UP has vanished, honestly re-runs the job and applies the requested
    /// switch on completion (R10).
    func switchVersion(for job: ToolJob) { useVersion(.runnerUp, for: job) }

    func useVersion(_ slot: VersionSlot, for job: ToolJob) {
        guard let row = versions(for: job),
              let shipped = row.shipped,
              let parked = slot == .runnerUp ? row.runnerUp : row.previous else { return }

        // Everything below assumes the delivered file is still where this row says it is. If the
        // user deleted or moved it outside the app (there is no file watcher), the re-run tail
        // would quietly re-create it — and, worse, leave the regenerated pair mismatched, so a
        // later switch would ship one version under the other's label and byte count.
        guard FileManager.default.fileExists(atPath: shipped.url.path) else {
            reportSwitchFailure(job.id, "The compressed file is no longer where it was saved, "
                                      + "so there is no version to switch to.")
            return
        }

        if FileManager.default.fileExists(atPath: parked.url.path) {
            do {
                try store.switchVersions(shipped: shipped.url, runnerUp: parked.url)
                versionStore.swapShipped(with: slot, for: job.id)
                publishJobs()   // no state moved, but the row's badge/capsule read from the store
                return
            } catch let stranded as RunnerUpStore.SwitchError {
                // The shipped file is parked under a hidden name and nothing else will look for
                // it — re-running would write a new file over the top and bury it for good.
                reportSwitchFailure(job.id, stranded.localizedDescription)
                return
            } catch {
                // The switch did not happen and the shipped file is unchanged (store contract: any
                // other throw restores it) — the parked file raced away, so fall through.
            }
        }

        // Only the runner-up can be regenerated: a re-run reproduces the row's OWN preset, which by
        // definition is not the previous version's, so re-running for a vanished PREVIOUS version
        // would hand the user a different file under its label. The shipped result is perfectly
        // fine here — only the parked copy is gone — so this is a message beside the row, never a
        // `.failed` state that would hide a good result.
        guard slot == .runnerUp else {
            versionStore.setSlot(.previous, to: nil, for: job.id)
            recompressErrors[job.id] = "That version is no longer available — recompress at "
                                     + "\(parked.preset.title) to get it back."
            publishJobs()
            return
        }
        rerunForSwitch(job, wantHeavy: parked.variant == .mrc)
    }
```

- [ ] Point `rerunForSwitch` at the store — **its URLs as well as its preset**. Today's guard
      reads `job.resultURL` and `job.alternateURL`, and after this feature lands both are wrong:
      `resultURL` is the queue's record of the FIRST run, superseded by every recompress commit
      (which writes to the row's path but never updates the queue's job), and it is `nil` outright
      on a no-gain row that a recompress later promoted — so "Use this" would silently do nothing
      on exactly the rows this feature creates. Derive both from the store, as `useVersion` does:

```swift
    private func rerunForSwitch(_ job: ToolJob, wantHeavy: Bool) {
        // The STORE, never `job.resultURL`/`job.alternateURL`: the queue's record is the first
        // run's and a recompress supersedes it without touching the queue. This tail is only ever
        // reached for a vanished RUNNER-UP (`useVersion` guards `slot == .runnerUp` before
        // calling), so the record still holds both URLs even though the runner-up file is gone —
        // and the runner-up slot is reused in place, so nothing new is reserved here.
        guard let engine,
              let row = versionStore.versions(for: job.id),
              let shipped = row.shipped?.url,
              let runnerUp = row.runnerUp?.url else { return }
        let chosen = row.rowPreset
```

      `rowPreset` is the invariant `testLaterBatchDoesNotRewriteAFinishedRowsPreset` pins (the old
      `jobPresets[job.id] ?? preset` said the same thing through the retired bookkeeping). The two
      `switched` flips in the tail become store operations. Where it recorded "regenerated
      canonical state: heavy shipped, runner-up present" (`switched.remove(id)`), the regenerated
      pair is written back with the SAME byte counts and preset the row already had — the re-run
      reproduces the row, it does not redefine it:

```swift
                        // Regenerated canonical state: heavy shipped, runner-up parked. If the row
                        // was showing the parked version before the re-run, swap the descriptions
                        // back — the re-run reproduces the row's own pair, it never redefines it,
                        // so no new byte counts are invented here.
                        if versionStore.versions(for: id)?.shipped?.variant != .mrc {
                            versionStore.swapShipped(with: .runnerUp, for: id)
                        }
```

      and the `if !wantHeavy` branch's `switched.insert(id)` becomes
      `versionStore.swapShipped(with: .runnerUp, for: id)` on a successful `store.switchVersions`.
- [ ] Funnel every removal through the store: `discardRunnerUp(for:)` becomes
      `versionStore.discardRow(job.id)` plus a NEW `switchFailures[job.id] = nil` line — today's
      body clears `switched`/`jobPresets`/`batchAlternates` and does not touch `switchFailures`.
      This is tidiness, not a defect fix: `ToolJob.init` mints a fresh `UUID` per `add`, so a
      re-added row can never key into the removed row's entry, and `pruneStaleEstimateState`
      already filters `switchFailures` on every sink emission. The line simply clears the removed
      row's message at removal time rather than one emission later, keeping every removal path in
      one place. Then `pruneStaleEstimateState` calls `versionStore.retain(only: liveIDs)` where it
      filtered `switched`/`jobPresets`, and inherits `jobPresets`' other guard as well —
      **replacing a piece of bookkeeping means inheriting its lifecycle guards**, and the two
      dictionaries that take over its roles are otherwise never filtered:

```swift
        pendingPresets = pendingPresets.filter { liveIDs.contains($0.key) }
        recompressErrors = recompressErrors.filter { liveIDs.contains($0.key) }
```

      `pendingPresets` takes over `jobPresets`' IN-FLIGHT role and, unlike it, is consumed on
      ingest — but only for a `.done` job. A `.failed` job never reaches `ingestCompletedJobs`'s
      switch, so its entry is never consumed and would outlive the row without this line.
      `recompressErrors` (declared earlier in this task) is cleared only at the start of the next run
      and on a preset change, neither of which fires when a row is simply removed.
- [ ] Rewrite `cancel()`'s reclaim over the reservation ledger, keeping the exact rule the
      `isDoneHeavy` check encoded (a reservation the store now owns as a committed runner-up is
      kept; everything else is reclaimed):

```swift
    func cancel() {
        queue.cancel()
        // Discard the in-flight batch's runner-up reservations, except any the store has since
        // claimed as a committed version. A cancelled job returns to `.queued` and, by the engine's
        // atomic-write contract, leaves no partial output — so this only reclaims files a
        // completed-but-superseded job wrote before the cancel landed (R18).
        for (id, url) in runReservations where versionStore.versions(for: id)?.runnerUp?.url != url {
            store.discard(url)
        }
        runReservations = [:]
    }
```

      and delete `isDoneHeavy`.
- [ ] Run the view-model suite; every pre-existing test passes unchanged in meaning:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/CompressViewModelTests
```

- [ ] Deleting `HeavyVersions` breaks its two consumers, so both move in this same commit — Phase 1
      must not end on a branch that does not build:
      - `HeavyCompressionPopover`: `let versions: CompressViewModel.HeavyVersions` becomes
        `let versions: RowVersions`. Every member it reads — `shippedIsHeavy`, `heavyBytes`,
        `normalBytes`, `shippedURL`, `runnerUpURL`, `runnerUpIsOriginal` — is optional on
        `RowVersions`, and `heavyURL`/`normalURL` are non-optional `URL` today. **The decision is
        to unwrap ONCE at the top of `body`, keeping every downstream accessor non-optional**,
        rather than push optionality through every card, byte line and label for a file Task 6
        deletes:

```swift
    var body: some View {
        // This popover only ever draws for a row with both versions: `versions(for:)` returned
        // nil otherwise, and the capsule that opens it is drawn only on a `.doneHeavy` row —
        // which Task 12 derives from `row.count > 1`, i.e. exactly the rows that have a pair.
        // One unwrap here keeps the card code identical to today's.
        if let shipped = versions.shipped, let runnerUp = versions.runnerUp {
            content(shipped: shipped, runnerUp: runnerUp)
        }
    }
```

        with today's body moved verbatim into
        `private func content(shipped: FileVersion, runnerUp: FileVersion) -> some View`, and
        inside it: `versions.shippedIsHeavy` → `shipped.variant == .mrc`;
        `versions.heavyBytes` → `(shipped.variant == .mrc ? shipped : runnerUp).bytes`;
        `versions.normalBytes` → `(shipped.variant == .mrc ? runnerUp : shipped).bytes`;
        `heavyURL` → `(shipped.variant == .mrc ? shipped : runnerUp).url`;
        `normalURL` → `(shipped.variant == .mrc ? runnerUp : shipped).url`;
        `normalTitle` →
        `((shipped.variant == .mrc ? runnerUp : shipped).variant == .original) ? "Original" : "Normal"`
        — the same positional selector shape as `normalURL` above, deliberately: the title must
        describe whichever record currently occupies the NORMAL position, and `swapShipped` moves
        records between the shipped and runner-up positions, so keying the label off
        `runnerUp.variant` would make the button lie the moment the user switches. (`heavyURL`,
        `normalURL` and `normalTitle` become parameters of, or locals inside, `content` — they
        can no longer be computed properties, because they now need the unwrapped pair.) Copy and
        geometry unchanged — Task 6 generalises it; this step only keeps it compiling.
      - `CompressView`: `model.heavyVersions(for: job)` → `model.versions(for: job)`,
        `versions.capsuleTitle` unchanged, `onPreview`'s pair read from
        `versions.cards.map(\.version.url)`, and `originalBytes(for:)` reading
        `model.versions(for: job)?.originalBytes ?? 0`,
        and `status(for:)`'s `.compressedHeavy` arm's `newBytes: versions.displayedBytes` →
        `newBytes: versions.shipped?.bytes ?? after` — the `guard let versions` is already in
        scope; this is the interim behaviour-preserving form, replaced wholesale by Task 12's
        store-driven `.done` arm.
- [ ] Build to prove the whole app still compiles:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
```

- [ ] Commit: `refactor(compress): make the version store the display authority for row versions`

---

# Phase 2 — parallel fork

Track P and Track E start from the merged Phase-1 branch and may run concurrently in separate
worktrees. Their file sets are disjoint and neither consumes a symbol the other introduces.

## Track P — presentation (Tasks 5–6)

### Task 5: FileRow leading affordances and the accent banner

**Model:** sonnet · **Track:** P

The armed/futile/instant-switch/error affordances all occupy the same leading slot in a finished
row's trailing cluster (mockup screens 2 and 5), and the armed banner is the success banner in the
accent tone (mockup screen 2). Both are presentation-only: `FileRow` and `SuccessBanner` stay free
of `ToolJob`/`CompressPreset`, as the design system's contract requires.

**Files**
- Modify: `Sources/Toolbox/DesignSystem/Components.swift`

**Interfaces**
- Consumes: `Theme.Colors.{accent,textTertiary,link,text}`, `StatPill`, `LinkButton`
- Produces:
  - `FileRow.Lead` (`.accentPill(String)`, `.neutralPill(String)`, `.link(String)`, `.error(String)`)
  - `FileRow.lead: Lead?`, `FileRow.onLeadTap: (() -> Void)?`, `FileRow.metaAccent: String?`
  - `SuccessBanner.Tone` (`.success`, `.accent`) and `SuccessBanner.tone: Tone`

**Steps**

- [ ] Add to `FileRow`, above `@State private var isHoveringCapsule`:

```swift
    /// The leading item of a finished row's trailing cluster: the armed prediction, a
    /// known-futile note, an instant-switch link, or a per-row error. Additive — the row keeps its
    /// whole done cluster behind it, so nothing ever reads as lost (R2).
    enum Lead: Equatable {
        case accentPill(String)
        case neutralPill(String)
        case link(String)
        case error(String)
    }

    var lead: Lead?
    /// Action for a `.link` lead. Ignored by every other shape.
    var onLeadTap: (() -> Void)?
    /// A second, accent-toned clause appended to the meta line ("· will recompress at Balanced").
    var metaAccent: String?
```

- [ ] Render the accent clause beside `meta` (replacing the single `Text(meta)`):

```swift
                    HStack(spacing: 4) {
                        Text(meta).themeFont(.micro).foregroundStyle(Theme.Colors.textTertiary)
                        if let metaAccent {
                            Text("· \(metaAccent)").themeFont(.micro)
                                .foregroundStyle(Theme.Colors.accent)
                                .lineLimit(1)
                        }
                    }
```

- [ ] Add the lead view and draw it first in ALL THREE finished clusters — `.done`, `.doneHeavy`
      **and `.unchanged`** — so an armed row keeps its full done cluster behind its lead.

      `.unchanged` is not optional here and not a nicety: a no-gain row renders `.unchanged`, and
      no-gain rows are precisely the rows R1 arms ("still too big" is exactly their user) and
      precisely the rows R6's futile caption describes. Left as today's bare `Label`, the armed
      pill and the futile pill would be invisible on the only rows the spec names for them. The
      approved mockup draws it exactly this way — pill, then muted check, then the note:
      `<span class="pill accent">→ may not shrink</span><span class="muted-check">✓</span><span class="fsub">Already optimised</span>`.
      So the `.unchanged` arm becomes:

```swift
        case .unchanged(let message):
            // Lead first, then today's muted check and note — a no-gain row is armable (R1) and
            // futile-markable (R6), so it must be able to carry a lead like any finished row.
            HStack(spacing: 11) {
                leadView
                Label {
                    Text(message).themeFont(.micro).lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            // A lead makes this the widest this cluster has ever been; without fixedSize, width
            // pressure wraps the pill onto two lines and grows the row (R8's single-line height).
            // The name column absorbs the squeeze instead (lineLimit + middle truncation).
            .fixedSize()
```

      and `.done`/`.doneHeavy` gain `leadView` as the first child of their existing `HStack`
      (before the struck original size). `.doneHeavy` already carries `.fixedSize()` for exactly
      this reason; `.done` now needs it too, because the lead widens it the same way, so its
      `HStack` gains the same modifier and the same one-line reason:

```swift
            // A lead makes this the widest this cluster has ever been; without fixedSize, width
            // pressure wraps the pill onto two lines and grows the row (R8's single-line height).
            // The name column absorbs the squeeze instead (lineLimit + middle truncation).
            .fixedSize()
```

      (Neither previews nor the build can catch wrapping — it only shows under width pressure — so
      the modifier is added by rule, not on the evidence of a screenshot.) The lead view itself:

```swift
    @ViewBuilder
    private var leadView: some View {
        switch lead {
        case .accentPill(let text):
            StatPill(text: text, tone: .accent)
        case .neutralPill(let text):
            StatPill(text: text, tone: .neutral)
        case .link(let title):
            LinkButton(title: title) { onLeadTap?() }
        case .error(let message):
            Label {
                Text(message).themeFont(.micro).lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
```

- [ ] Give `SuccessBanner` its accent tone (the armed banner, R4) without a second component:

```swift
struct SuccessBanner: View {
    /// The banner's colour story: `.success` for a finished batch, `.accent` for the armed state,
    /// where nothing has happened yet and a green tick would claim otherwise (R4).
    enum Tone {
        case success, accent

        var color: Color {
            switch self {
            case .success: return Theme.Colors.success
            case .accent: return Theme.Colors.accent
            }
        }

        var symbol: String {
            switch self {
            case .success: return "checkmark"
            case .accent: return "arrow.triangle.2.circlepath"
            }
        }
    }

    let headline: String
    /// Optional: the armed banner has no detail line when no armed row has a confident prediction
    /// (R4), and an empty `Text` would leave a blank line where the caller means "say nothing".
    let detail: String?
    var tone: Tone = .success
```

      with the body's `Theme.Colors.success` occurrences replaced by `tone.color`,
      `Image(systemName: "checkmark")` by `Image(systemName: tone.symbol)`, and the detail line
      wrapped in `if let detail { … }`. The existing `SuccessBanner(headline:detail:)` call site in
      `CompressView` still compiles — a `String` promotes to `String?`.
- [ ] Extend the `fileRowStateGallery` preview with an armed row and an error-lead row so both
      appearances are visible in Xcode previews in light and dark:

```swift
        FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB · 32 pages",
                status: .doneHeavy(originalBytes: 18_700_000, newBytes: 1_600_000),
                lead: .accentPill("→ ≈0.9 MB"), metaAccent: "will recompress at Smallest")
        FileRow(name: "Board-Minutes.pdf", meta: "3.2 MB · 8 pages",
                status: .done(originalBytes: 3_200_000, newBytes: 1_400_000),
                lead: .error("Recompress failed — kept your Balanced version"))
        // The `.unchanged` lead, which is where the armed and futile pills actually live for a
        // no-gain row — the case the mockup's screens 2 and 5 both show.
        FileRow(name: "Already-Tiny.pdf", meta: "184 KB",
                status: .unchanged("Already optimised"),
                lead: .accentPill("→ may not shrink"), metaAccent: "will try Smallest")
        FileRow(name: "Dense-Scan.pdf", meta: "2.1 MB · 4 pages",
                status: .unchanged("Already optimised"),
                lead: .neutralPill("No saving at Smallest"))
```

- [ ] Build (the design system has no unit tests; the previews and the app build are its check):

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
```

- [ ] Commit: `feat(design-system): add row lead affordances and an accent banner tone`

---

### Task 6: The versions popover generalises to three cards

**Model:** sonnet · **Track:** P

**Files**
- Rename: `Sources/Toolbox/Compress/HeavyCompressionPopover.swift` →
  `Sources/Toolbox/Compress/VersionsPopover.swift` (use `git mv`; sources are glob-discovered, so
  `project.yml` needs no edit)
- Modify: the renamed file

**Interfaces**
- Consumes: `RowVersions`, `FileVersion`, `VersionSlot`, `EngineVariant`, `CompressPreset.title`,
  `PDFThumbnail`, `StatPill`, `Theme`
- Produces:
  - `struct VersionsPopover: View` with
    `init(versions: RowVersions, onUse: @escaping (VersionSlot) -> Void, onPreview: @escaping (URL) -> Void)`

**Steps**

- [ ] `git mv Sources/Toolbox/Compress/HeavyCompressionPopover.swift Sources/Toolbox/Compress/VersionsPopover.swift`
- [ ] Rewrite the body, keeping the existing card geometry, thumbnail button, byte line and
      savings-pill rule verbatim:

```swift
/// The capsule's popover: every version of a row side by side with real thumbnails and on-disk
/// sizes; any non-current card can be brought back with one click (R15). Two cards keep today's
/// 340 pt layout; a third — the previous version a recompress parked — widens it to 470 pt.
struct VersionsPopover: View {
    let versions: RowVersions
    let onUse: (VersionSlot) -> Void
    let onPreview: (URL) -> Void

    /// 340 pt for two cards (today's geometry, unchanged), 470 pt for three.
    private var width: CGFloat { versions.count > 2 ? 470 : 340 }

    private var title: String { versions.previous == nil ? "Heavy compression" : "Versions" }

    private var blurb: String {
        versions.previous == nil
            ? "This scan was rebuilt in compact layers. Text stays sharp, but fine background detail can soften. Both versions are ready — compare and pick."
            : "Every version of this file that is still on disk. Preview any of them, and bring one back with a click. Versions live until the app closes or the row is cleared."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                Text(blurb)
                    .themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                ForEach(Array(versions.cards.enumerated()), id: \.offset) { _, card in
                    versionCard(card.version, slot: card.slot)
                }
            }
        }
        .padding(16)
        .frame(width: width)
    }

    /// "Smallest · Heavy", "Smallest · Normal", "Balanced (previous)" — the preset is what the user
    /// chose and the variant is what the engine did with it, so a card names both.
    private func label(_ version: FileVersion, slot: VersionSlot?) -> String {
        if slot == .previous { return "\(version.preset.title) (previous)" }
        switch version.variant {
        case .mrc: return "\(version.preset.title) · Heavy"
        case .plain: return "\(version.preset.title) · Normal"
        case .original: return "Original"
        }
    }

    private func versionCard(_ version: FileVersion, slot: VersionSlot?) -> some View {
        VStack(spacing: 6) {
            Button {
                onPreview(version.url)
            } label: { PDFThumbnail(url: version.url, width: 72) }
                .buttonStyle(.plain).clearsClickFocus().pointingHandCursor()
                .help("Preview this version")
                .accessibilityLabel("Preview the \(label(version, slot: slot)) version")
            Text(label(version, slot: slot)).themeFont(.microBold).foregroundStyle(Theme.Colors.text)
            HStack(spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(version.bytes), countStyle: .file))
                    .themeFont(.micro).foregroundStyle(Theme.Colors.textSecondary)
                // No pill on a non-saving version ("−0%" on the Original card is nonsense).
                if version.bytes < versions.originalBytes {
                    StatPill(text: savedText(version.bytes), tone: .success)
                }
            }
            if let slot {
                Button("Use this") { onUse(slot) }
                    .buttonStyle(.plain)
                    .clearsClickFocus()
                    .font(Theme.Typography.caption.font).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.vertical, 5).padding(.horizontal, 12)
                    .background(Theme.Colors.accent,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .pointingHandCursor()
            } else {
                Text("Current").themeFont(.micro).foregroundStyle(Theme.Colors.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Theme.Colors.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(slot == nil ? Theme.Colors.accent : .clear, lineWidth: 1.5))
    }

    private func savedText(_ bytes: Int) -> String {
        "−\(Int((1 - Double(bytes) / Double(max(versions.originalBytes, 1))) * 100))%"
    }
}
```

- [ ] Build:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
```

      (`CompressView` still references `HeavyCompressionPopover`; update that one call site to
      `VersionsPopover(versions:onUse:onPreview:)` in this task so the branch compiles, passing
      `onUse: { slot in quickLookURL = nil; model.useVersion(slot, for: job); heavyPopoverJobID = nil }`
      — the surrounding armed/banner wiring stays with Task 11.)
- [ ] Commit: `feat(compress): generalise the heavy popover into a three-card versions popover`

---

## Track E — arming and execution (Tasks 7–10)

Track E never touches `CompressView.swift`; every affordance it adds is consumed by Phase 3.

### Task 7: Derived arming state

**Model:** opus · **Track:** E

Arming is **derived, never stored**: a pure function of the selected preset, the row's recorded
versions and its futile records. That is what makes R3's reversibility free — there is no armed set
to unwind, so re-selecting the row's own preset disarms it by construction.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `RowVersions.rowPreset`, `RowVersions.previous`, `VersionStore.versions(for:)`
- Produces:
  - `enum CompressViewModel.RowRecompressState { case none; case futile(CompressPreset); case instantSwitch(CompressPreset); case armed(CompressPreset) }`
  - `func recompressState(for job: ToolJob) -> RowRecompressState`
  - `var armedCount: Int`

**Steps**

- [ ] Extend the test file's `StubEngine` with a per-call script seam (the default keeps every
      existing test's behaviour byte-for-byte), and add the new tests:

```swift
        /// What one scripted call writes and returns, so a recompress can differ from the run that
        /// produced the row.
        struct Response {
            let outcome: JobOutcome
            /// Bytes to write at the primary output, or nil to write nothing (a no-gain run).
            let shippedBytes: Int?
            /// Bytes to write at the alternate output, or nil to leave that slot empty.
            let runnerUpBytes: Int?
        }
        /// Per-call script (1-based call index). Nil keeps the fixed outcome the initialiser took.
        var script: ((Int, CompressPreset) -> Response)?
        /// When set, the engine throws on this 1-based call instead of writing anything.
        var throwOnCall: Int?
```

      with `compress` resolving the response first:

```swift
            callCount += 1
            presets.append(preset)
            if throwOnCall == callCount { throw CompressError.validationFailed }
            let response = script?(callCount, preset)
                ?? Response(outcome: outcome, shippedBytes: shippedBytes, runnerUpBytes: runnerUpBytes)
```

      and each write guarded on its optional (`if let bytes = response.shippedBytes { … }`), keeping
      the existing never-overwrite `fileExists` guards in place — a stub that overwrites where
      production refuses greens a dead re-run path.

```swift
    // MARK: arming (R1/R3/R6/R7)

    /// Selecting a different preset with finished rows showing arms them; the row's own preset
    /// leaves it alone (R1).
    func testSelectingADifferentPresetArmsAFinishedRow() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .none,
                       "the row's own preset must not arm it")

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))
        XCTAssertEqual(model.armedCount, 1)
    }

    /// R3: re-selecting the row's preset disarms it instantly, leaving no residue.
    func testReselectingTheRowsPresetDisarmsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 1)
        model.preset = .balanced
        XCTAssertEqual(model.armedCount, 0)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none)
    }

    /// A `.failed` row never arms — its recourse is re-adding the file, not a re-run (R1).
    func testFailedRowsNeverArm() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.throwOnCall = 1
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        guard case .failed = job.state else { return XCTFail("expected a failed row, got \(job.state)") }
        XCTAssertEqual(model.recompressState(for: job), .none)
        XCTAssertEqual(model.armedCount, 0)
    }

    /// A no-gain row arms at a DIFFERENT preset ("still too big" is exactly its user) but reports
    /// its own preset as futile rather than re-arming a known-futile run (R1/R6).
    func testNoGainRowArmsElsewhereAndIsFutileAtItsOwnPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .futile(.balanced))

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize), "a no-gain row is the 'still too big' case — it arms")
    }

    /// R7: when the parked previous version was made at the selected preset, the row offers an
    /// instant switch instead of arming a recompute of a file already in the cache.
    func testPreviousVersionsPresetOffersAnInstantSwitchRatherThanArming() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        // Recompress at Smallest, parking the Balanced version.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .instantSwitch(.balanced))
        XCTAssertEqual(model.armedCount, 0)
    }

    /// Nothing arms while a run is in flight — the selector is disabled for the duration (R9), and
    /// the state must agree with the control.
    func testNothingArmsWhileARunIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        let gate = Gate()
        env.stub.gate = gate
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 0)
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }
    }
```

- [ ] Run and watch them fail:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/CompressViewModelTests
```

- [ ] Implement in `CompressViewModel`:

```swift
    /// What selecting the current preset means for one finished row (R1/R6/R7). Derived on every
    /// read from the row's versions and futile records — never stored, so re-selecting the row's
    /// own preset disarms it with nothing to unwind (R3).
    enum RowRecompressState: Equatable {
        case none
        /// This row already came back with no saving at that preset; saying so beats re-running it.
        case futile(CompressPreset)
        /// The parked previous version was made at that preset — switch, don't recompute.
        case instantSwitch(CompressPreset)
        /// Will recompress at that preset when the button is pressed.
        case armed(CompressPreset)
    }

    /// A recompress attempt that came back with no saving. Dies with the row (Clear finished /
    /// remove) and with the session; never persisted.
    private struct FutileAttempt: Hashable {
        let id: ToolJob.ID
        let preset: CompressPreset
    }
    private var futileAttempts: Set<FutileAttempt> = []

    func recompressState(for job: ToolJob) -> RowRecompressState {
        // Nothing arms mid-run: the selector is disabled for the duration (R9), and an armed row
        // whose file is being rewritten underneath it would be describing a moving target.
        guard !isRunning else { return .none }
        guard case .done(let outcome) = job.state else { return .none }
        switch outcome {
        // A `.failed` row never arms (its recourse is re-adding the file); OCR outcomes never
        // reach this view model's rows.
        case .ocrAdded, .alreadySearchable: return .none
        case .compressed, .compressedHeavy, .noGain: break
        }
        // A row whose delivered file could not be backed any more has nothing to recompress from.
        guard let row = versions(for: job) else { return .none }
        let target = preset
        // Ahead of the row-preset check on purpose: a row that came back no-gain at its own preset
        // must show the futile caption rather than read as a plain, unremarkable finished row.
        if futileAttempts.contains(FutileAttempt(id: job.id, preset: target)) { return .futile(target) }
        if row.rowPreset == target { return .none }
        if row.previous?.preset == target { return .instantSwitch(target) }
        return .armed(target)
    }

    /// The rows one press would recompress (R5's M).
    var armedJobs: [ToolJob] {
        jobs.filter { if case .armed = recompressState(for: $0) { return true }; return false }
    }

    var armedCount: Int { armedJobs.count }
```

- [ ] Record the futile attempt where a no-gain outcome is ingested (`ingestCompletedJobs`'s
      `.noGain` case gains `futileAttempts.insert(FutileAttempt(id: job.id, preset: preset))` — R6's
      "a first-run no-gain at P0 records (job, P0) as futile exactly as a recompress no-gain does"),
      and prune it alongside everything else in `pruneStaleEstimateState`:
      `futileAttempts = futileAttempts.filter { liveIDs.contains($0.id) }`.
- [ ] Run the suite; all green.
- [ ] Commit: `feat(compress): derive the armed/futile/instant-switch state for finished rows`

---

### Task 8: The armed row's prediction

**Model:** opus · **Track:** E

R16: scale the estimator's per-preset figure by the row's observed ratio **only** when the engine
path is expected to repeat; whenever it changes in either direction, use the raw gs estimate,
because a ratio learned on one path does not transfer to the other.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `CompressEstimator.Analysis`, `RowVersions`, `EngineVariant`, `PDFContentType`
- Produces: `func recompressPrediction(for job: ToolJob, at target: CompressPreset) -> Int?`
  (nil ⇒ the row renders "may not shrink")

**Steps**

- [ ] Write the failing tests. They drive the boundary directly through the two seams the model
      already owns, with a stub analyser so the estimator's own numbers are deterministic:

```swift
    // MARK: recompress prediction (R16)

    /// A row whose engine path repeats scales the raw estimate by what the engine actually did —
    /// the calibration that stops an MRC row's recompression being predicted as a 4× growth.
    func testPredictionScalesByTheObservedRatioWhenThePathRepeats() async throws {
        // `.scanColour` at `.smallestSize` is the only pair reachable from this row's `.balanced`
        // shipped preset giving
        // `targetWantsMRC == shippedWasMRC == true` with a non-degenerate ratio: `HeavyEnv` always
        // ships `.compressedHeavy` (`shippedWasMRC` is always true), so the repeating-path case
        // needs a target that is ALSO MRC-eligible — `.scanColour` + a non-Maximum preset — not
        // `.bornDigital`, which is never MRC-eligible and so never repeats the path.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let balanced = try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes)
        let smallest = try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes)
        // Associated EXACTLY as the implementation associates it: `Int(_:)` truncates, so a
        // differently-bracketed expression of the same real number can land one byte away.
        let expected = Int((Double(HeavyEnv.heavyBytes) / Double(balanced)) * Double(smallest))

        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        XCTAssertEqual(predicted, expected,
                       "a scanColour row shipped MRC and staying MRC-eligible at Smallest Size has "
                       + "a path that repeats, so the observed ratio applies")
    }

    /// A `.scanColour` row that shipped MRC crossing to Maximum quality (never MRC-eligible) must
    /// use the RAW estimate — the ratio was learned on a path that will not run.
    func testPredictionUsesTheRawEstimateWhenTheEnginePathChanges() async throws {
        // A large original, so the "must beat the original" guard cannot mask the calibration rule
        // this test exists to pin.
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let raw = try XCTUnwrap(analysis.estimates[.maximumQuality]?.predictedBytes)

        XCTAssertEqual(model.recompressPrediction(for: job, at: .maximumQuality), raw,
                       "an MRC-shipped row crossing to Maximum quality gets the raw gs estimate")
    }

    /// Any prediction at or above the original renders as "may not shrink", never a confident
    /// number (R16) — the model says so by returning nil.
    func testPredictionIsWithheldWhenItWouldNotBeatTheOriginal() async throws {
        // This row takes the RAW-estimate branch, not the scaled one: the shipped version is MRC
        // (`HeavyEnv` produces `.compressedHeavy`) while `.bornDigital` + `.maximumQuality` gives
        // `targetWantsMRC == false`, so the paths differ and no calibration is applied. The guard
        // then fires deterministically because the raw estimate is derived from the REAL fixture,
        // which is far larger than the 1 kB original the stub reports — so `predicted` cannot be
        // below `row.originalBytes` whatever the estimator predicts.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
    }

    /// R10's ARMING half: the missing-original guard fires before a confident number is offered,
    /// not only before the run. A row whose input has been deleted must not display a pill
    /// promising a size the app has no way to produce.
    func testPredictionIsWithheldWhenTheOriginalIsGone() async throws {
        // `.scanColour`, so the POSITIVE control is genuinely confident before the deletion. The
        // shipped version is MRC and `.scanColour` + `.smallestSize` gives `targetWantsMRC == true`,
        // so `targetWantsMRC == shippedWasMRC` and the calibration branch runs: the prediction
        // tracks the shipped 1.2 kB (scaled by raw/baseline), comfortably under the 9 kB original.
        // With `.bornDigital` the paths would differ, the RAW estimate would be used, and that is
        // derived from the multi-megabyte `imagePDF` fixture — the "must beat the original" guard
        // would return nil before the deletion too, and the test would assert nothing.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressPrediction(for: job, at: .smallestSize),
                        "the row predicts confidently while its input is still there")

        try FileManager.default.removeItem(at: env.input)
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize),
                     "no input, no prediction — R10 applies at arming time, not just at run time")
        XCTAssertTrue(model.isOriginalMissing(for: job))
    }
```

      `HeavyEnv` gains a `contentType:` parameter that injects a stub `PDFAnalysing` into the
      estimator, so the classification is fixed rather than whatever the fixture happens to classify
      as:

```swift
        init(before: Int = 9000, contentType: PDFContentType? = nil) throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mrc-track-b-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            storeRoot = tmp.appendingPathComponent("cache", isDirectory: true)
            let outputFolder = tmp.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: outputFolder,
                                                    withIntermediateDirectories: true)

            input = try Fixtures.imagePDF()
            stub = StubEngine(outcome: .compressedHeavy(before: before,
                                                        after: HeavyEnv.heavyBytes,
                                                        runnerUpBytes: HeavyEnv.normalBytes),
                              shippedBytes: HeavyEnv.heavyBytes,
                              runnerUpBytes: HeavyEnv.normalBytes)
            // The ONLY change to the existing body: the estimator is injected when a caller pins
            // the classification, and is the default otherwise, so every existing `HeavyEnv()`
            // call site behaves exactly as before.
            let estimator = contentType.map {
                CompressEstimator(analyser: FixedAnalyser(contentType: $0))
            } ?? CompressEstimator()
            model = CompressViewModel(engine: stub, estimator: estimator,
                                      store: RunnerUpStore(rootOverride: storeRoot))
            model.outputFolder = outputFolder
        }

    /// A `PDFAnalysing` that answers with a fixed classification, so a prediction test pins the
    /// R16 boundary rather than whatever a fixture happens to classify as.
    private struct FixedAnalyser: PDFAnalysing {
        let contentType: PDFContentType
        func pageCount(_ url: URL) throws -> Int { 1 }
        func classify(_ url: URL) throws -> PDFContentType { contentType }
    }
```

- [ ] Run and watch them fail.
- [ ] Implement in `CompressViewModel`:

```swift
    /// The analysis behind a row's estimates — exposed so the prediction's calibration can be
    /// asserted against the same numbers the row displays.
    func analysis(for job: ToolJob) -> CompressEstimator.Analysis? { analyses[job.id] }

    /// R10's arming half: a recompress always reads the ORIGINAL input (D2), so a row whose input
    /// has gone cannot be recompressed at all — and must not advertise a prediction, or offer the
    /// armed pill, as if it could. Checked on every read rather than cached, exactly like the
    /// arming state itself: there is no file watcher, so a stored answer would go stale silently.
    /// The view turns this into the R10 error lead; the model refuses the number.
    ///
    /// One `stat` per ARMED row per body evaluation — bounded by the armed count, not the queue
    /// length, because `lead(for:)` only reaches it inside the `.armed` arm. `useVersion` already
    /// stats on the same rows at event time, so this adds no new class of I/O. Not cached, for the
    /// reason above; if the armed count ever grows large enough for this to matter, the answer is
    /// a file-presence watcher, not a stale cache.
    func isOriginalMissing(for job: ToolJob) -> Bool {
        !FileManager.default.fileExists(atPath: job.url.path)
    }

    /// The armed row's predicted size at `target`, or nil when no confident number can be given —
    /// the row then reads "may not shrink" (R16). The "≈" marker is the view's, and stays whatever
    /// this returns: the figure is always approximate.
    ///
    /// The estimator models the gs path only, so its figure is calibrated by what the engine
    /// actually did — but ONLY when the same path is expected to run again. `wantsMRC` is
    /// `classification == .scanColour && preset != .maximumQuality`, so an MRC-shipped row crossing
    /// to Maximum quality, or a gs-shipped row moving to an MRC-eligible preset, both change path
    /// and take the raw estimate: a ratio learned on one path does not transfer to the other.
    func recompressPrediction(for job: ToolJob, at target: CompressPreset) -> Int? {
        // Ahead of everything: a confident number for a row that cannot run is the one thing R10
        // names explicitly ("and before arming shows a confident estimate").
        guard !isOriginalMissing(for: job) else { return nil }
        guard let analysis = analyses[job.id],
              let raw = analysis.estimates[target]?.predictedBytes,
              let row = versions(for: job) else { return nil }

        var predicted = raw
        if let shipped = row.shipped,
           // A shipped `.original` is the untouched input, not an engine result — there is no
           // observed ratio in it to calibrate with.
           shipped.variant != .original,
           let baseline = analysis.estimates[shipped.preset]?.predictedBytes, baseline > 0 {
            let targetWantsMRC = analysis.contentType == .scanColour && target != .maximumQuality
            let shippedWasMRC = shipped.variant == .mrc
            if targetWantsMRC == shippedWasMRC {
                predicted = Int((Double(shipped.bytes) / Double(baseline)) * Double(raw))
            }
        }
        // A prediction that does not beat the original is never shown as a confident number.
        guard predicted < row.originalBytes else { return nil }
        return predicted
    }

    /// R4's banner data: how much the armed set is predicted to save on top of what the rows
    /// already shipped. `extraSaving` is summed over armed rows with a CONFIDENT prediction only —
    /// a "may not shrink" row contributes nothing — and is nil when no armed row has one, so the
    /// banner shows no detail line at all rather than a fabricated zero.
    struct ArmedSummary: Equatable {
        let armedCount: Int
        let queuedCount: Int
        let extraSaving: Int?
    }

    var armedSummary: ArmedSummary? {
        let armed = armedJobs
        guard !armed.isEmpty else { return nil }
        var total = 0
        var confident = false
        for job in armed {
            guard let predicted = recompressPrediction(for: job, at: preset),
                  let row = versions(for: job) else { continue }
            confident = true
            total += (row.shipped?.bytes ?? row.originalBytes) - predicted
        }
        return ArmedSummary(armedCount: armed.count, queuedCount: pendingCount,
                            extraSaving: confident ? total : nil)
    }
```

      (`pendingCount` moves onto the model in Task 10; until then use the same predicate inline and
      let Task 10 collapse it.)
- [ ] Run the suite; all green.
- [ ] Commit: `feat(compress): predict an armed row's size, calibrated only when the path repeats`

---

### Task 9: The direct-engine recompress and its commit protocol

**Model:** opus · **Track:** E

R8/R10/R11/R12/R13. A recompress never re-queues through `ToolQueue` — `execute` collects `.queued`
only, cancel maps to `.queued` and `setState` drops running ticks on done jobs, so the re-queue
route destroys the delivered state this feature exists to protect.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `Compressing.compress(_:preset:to:alternateOutput:mrcReport:progress:)`,
  `RunnerUpStore.promote(fresh:to:parking:)`, `VersionStore.{setSlot,setShipped,recordAttempt}`,
  `FileNaming.{output,reservationKey}`, `SystemInfo.performanceCoreCount`
- Produces:
  - `private struct RecompressPlan { let id: ToolJob.ID; let url: URL; let target: CompressPreset; let output: URL; let temp: URL; let parked: URL; let runnerUp: URL }`
  - `private(set) var recompressErrors: [ToolJob.ID: String]`
  - `compress()` gains a recompress phase over the armed rows

**Steps**

- [ ] Write the failing tests:

```swift
    // MARK: recompress commit protocol (R10–R13)

    /// The happy path: the fresh result takes the row's existing output path, the version it
    /// replaced is parked as the previous version, and every aggregate follows the new one.
    func testRecompressCommitsAndParksThePreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(row.shipped?.url, shippedURL, "a recompress writes to the row's own output")
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(try fileSize(shippedURL), 700, "the delivered file holds the new version")
        let previous = try XCTUnwrap(row.previous)
        XCTAssertEqual(previous.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(previous.preset, .balanced)
        XCTAssertEqual(try fileSize(previous.url), HeavyEnv.heavyBytes,
                       "the version the user had is parked intact")
        XCTAssertEqual(model.displayedSizes(for: job)?.after, 700)
    }

    /// R12: an engine failure keeps the version the user had, on disk and on screen, and says so.
    func testRecompressFailureKeepsThePreviousVersionAndReportsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the user's file must be exactly as it was")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Recompress failed — kept your Balanced version")
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.versions(for: job)?.previous, "a failed commit parks nothing")
        // The failure message and the armed state COEXIST: a failed recompress leaves the row's
        // preset at Balanced while the selector still says Smallest, so the row is armed again —
        // and the message must survive that, or the user is told nothing about what just failed.
        // This is the pair the view's `lead(for:)` has to resolve in the error's favour.
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "a failed attempt does not record a preset, so the row re-arms (R1)")
    }

    /// R12's message survives until the user moves on, and no longer: changing preset is the user
    /// saying "never mind that, what about this?", and the next run clears it as stale.
    func testARecompressErrorClearsWhenThePresetChangesOrTheNextRunStarts() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressErrors[job.id])

        model.preset = .maximumQuality
        XCTAssertNil(model.recompressErrors[job.id],
                     "the user moved on; a message about the Smallest attempt is now stale")

        // The SECOND half of this test's own name: the next run clears it too. Fail the row again
        // (the preset change re-armed it at Maximum quality), then start a fresh run and assert the
        // message is gone — `compress()` clears `recompressErrors` at the START of the run, so it
        // must be absent while that run is still in flight, not merely after it settles.
        env.stub.throwOnCall = env.stub.callCount + 1
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertNotNil(model.recompressErrors[job.id], "the Maximum-quality attempt failed too")

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        // The preset is deliberately LEFT at Maximum quality: a failed recompress records no
        // preset (R1), so the row is still armed at it and a fresh run needs no preset change.
        // Only the run's own clear can green the assertion below — the preset half this test
        // already covered cannot.
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }
        XCTAssertNil(model.recompressErrors[job.id],
                     "the next run clears the previous run's messages at its start")
        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    /// R9 + R12: cancelling during the QUEUE phase must stop the recompress phase before it
    /// starts. `queue.run` returns normally after a cancel, so nothing about the queue's own
    /// unwinding prevents phase 2 — only the run-scoped guard does.
    func testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // A newly queued row to occupy phase 1, and the finished row armed for phase 2.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        // Phase 1's job is in the engine, behind the gate.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must never reach the engine after a cancel in phase 1")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the armed row's delivered file is exactly as it was")
        XCTAssertNil(model.recompressErrors[try XCTUnwrap(model.jobs.first).id],
                     "a cancel is not a failure")
    }

    /// R9: cancelling an IN-FLIGHT recompress leaves the row's previous result and display
    /// untouched.
    ///
    /// The wait is on the stub's call count, deliberately, not on `model.isRunning`: with the
    /// run-scoped cancel guard in place, `isRunning` goes true before phase 2 begins, so a cancel
    /// fired on that signal alone would be caught by the guard and the engine would never be
    /// entered — the test would pass without ever exercising in-flight cancellation. Waiting for
    /// the call means the engine is genuinely suspended at the gate when the cancel lands.
    /// (`testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase` covers the other case.)
    func testCancellingARecompressKeepsThePreviousResult() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        // The armed row is inside the engine, suspended at the gate — see the note above.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.recompressErrors[job.id], "a cancel is not a failure")
    }

    /// R12: a no-gain recompress ships nothing and clears NOTHING — the shipped version, its URL
    /// and its parked versions all survive, and the row remembers the futile preset (R6).
    func testNoGainRecompressKeepsEveryReference() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let before = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))

        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let after = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(after.shipped, before.shipped, "nothing shipped, so nothing changed")
        XCTAssertEqual(after.runnerUp, before.runnerUp)
        XCTAssertNil(after.previous)
        XCTAssertEqual(try fileSize(try XCTUnwrap(after.shipped?.url)), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.recompressState(for: job), .futile(.smallestSize))
    }

    /// R11: the output path is pinned to the row's existing result even when "Save to" changed
    /// since the first run — a recompress replaces a file, it does not deliver a second one.
    func testRecompressWritesToTheRowsExistingResultPathAfterTheFolderChanged() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let elsewhere = env.storeRoot.deletingLastPathComponent()
            .appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        model.outputFolder = elsewhere

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url, shippedURL)
        XCTAssertEqual(try fileSize(shippedURL), 700)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)).isEmpty,
                      "a recompress must not deliver a second file into the new folder")
    }

    /// R11's reservation seeding: the commit makes the row's file transiently absent, so a queued
    /// same-basename job must be kept off that path by the RESERVATION, not by the file happening
    /// to exist when names are allocated. The DECOY is what makes this test discriminate: it
    /// pushes the armed row off the first free name, so with the seeding deleted the second
    /// batch's unfiltered allocation loop re-hands that row's freed name to the armed row and
    /// gives the NEW job exactly the armed row's shipped path.
    func testAQueuedJobNeverClaimsAnArmedRowsResultPath() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let outputFolder = try XCTUnwrap(model.outputFolder)
        // The decoy occupies `image-compressed.pdf`, so the armed row ships at
        // `image-compressed-1.pdf` rather than the first free name.
        let decoy = outputFolder.appendingPathComponent("image-compressed.pdf")
        try Data().write(to: decoy)

        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let armedRowOutput = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // Stand in for the promote window: the row's delivered file is momentarily not on disk —
        // and the decoy goes too, so `image-compressed.pdf` is free again and NOTHING on disk
        // stands between the new job and the armed row's path except the reservation.
        try FileManager.default.removeItem(at: decoy)
        try FileManager.default.removeItem(at: armedRowOutput)

        model.add([try Fixtures.imagePDF()])       // same basename, different folder
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let newRow = try XCTUnwrap(model.jobs.last)
        XCTAssertNotEqual(newRow.resultURL, armedRowOutput,
                          "the armed row's output must be reserved before any name is allocated")
    }

    /// R10: a vanished original stops that row before it starts, says so, and leaves its shipped
    /// result and versions intact. The rest of the batch is unaffected.
    func testMissingOriginalReportsPerRowAndLeavesTheResultIntact() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        try FileManager.default.removeItem(at: env.input)
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(env.stub.callCount, callsBefore, "no engine run without an input")
        XCTAssertEqual(model.recompressErrors[job.id], "The original file is no longer where it was")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertNotNil(model.versions(for: job)?.shipped)
    }
```

- [ ] Run and watch them fail.
- [ ] Implement in `CompressViewModel`. State first:

```swift
    /// One armed row's fully-allocated recompress: where it reads from, what it writes into, and
    /// the two cache slots its result may claim. Every path here comes from the up-front serial
    /// reservation pass — nothing is allocated once the concurrent work has started (R11).
    private struct RecompressPlan {
        let id: ToolJob.ID
        let url: URL
        let target: CompressPreset
        /// Where the result is delivered: the row's EXISTING result path, or — for a row that
        /// shipped nothing — a freshly reserved name from the current folder.
        let output: URL
        /// The engine never overwrites, so the result is written here and landed afterwards.
        let temp: URL
        /// The cache slot the version being replaced is parked into.
        let parked: URL
        let runnerUp: URL
    }

    /// Live progress for a row in the direct recompress path, overlaid onto the published job while
    /// `job.state` stays `.done` — the row's displayed state flips only at commit time (R8).
    private var recompressProgress: [ToolJob.ID: Double] = [:]
    // `recompressErrors` already exists (Task 4) and is reused here unchanged: deliberately NOT a
    // `.failed` state, because R12 requires the previous result to stay displayed and openable, so
    // the message rides beside the row's result instead of replacing it.

    /// The phase-2 task group's handle, so an in-flight recompress is cancelled too.
    private var recompressTask: Task<Void, Never>?
    /// Run-scoped cancellation flag, set by `cancel()` and cleared at the START of every run (R9).
    /// Two mechanisms cover the two windows a cancel can land in:
    /// 1. this flag + the guard before phase 2 stops the recompress phase ever STARTING after a
    ///    cancel that landed during phase 1 — `queue.run` returns normally on cancel, so without
    ///    the guard phase 2 begins as if nothing happened;
    /// 2. `recompressTask.cancel()` unwinds recompresses already in flight: it cancels the phase's
    ///    unstructured task, which propagates to its task-group children, so `Task.isCancelled` is
    ///    true inside `recompress` and its `try Task.checkCancellation()` throws before the commit.
    /// The flag is not merely a mirror of `Task.isCancelled`: `await task.value` on a
    /// non-throwing `Task` does not unwind on cancellation, so the explicit guard is load-bearing
    /// rather than decoration.
    private var runCancelled = false
    /// Rows of the current run that have reached a terminal point. A recompress row is `.done`
    /// from beginning to end (R8), so its state cannot carry this. Task 10 reads it for the
    /// progress bar and does NOT re-declare it; this is its single declaration, placed where the
    /// first writer lives.
    private var runCompleted: Set<ToolJob.ID> = []
```

- [ ] Overlay the progress in `publishJobs`, after the `switchFailures` branch and before the
      `isSwitchRerunning` one:

```swift
            } else if let fraction = recompressProgress[job.id] {
                display.state = .running(fraction)
```

- [ ] Extend `compress()`'s up-front reservation pass with the seeding and the armed plans (the
      queued allocation loop is unchanged). These two fragments are what THIS task adds; Task 10
      prints the finished `compress()` in full, and the fragments below appear there verbatim —
      if they ever disagree, Task 10's whole-function form is the authority:

```swift
        var reserved = Set<String>()
        // Seed every row's existing result path BEFORE allocating anything. A recompress commit
        // parks then promotes, so its file is transiently absent — a queued same-basename job must
        // be kept off that path by the reservation, never by the file happening to exist now (R11).
        for job in queue.jobs {
            if let shipped = versionStore.versions(for: job.id)?.shipped {
                reserved.insert(FileNaming.reservationKey(for: shipped.url))
            }
        }
```

      then, after the queued loop:

```swift
        let plans: [RecompressPlan] = armedJobs.map { job in
            let shipped = versionStore.versions(for: job.id)?.shipped
            // R11: the row's own result path, even if "Save to" changed since. A row that shipped
            // nothing (no-gain) has none, so it takes the name the loop above ALREADY allocated for
            // it — `jobs` is a 1:1 map of `queue.jobs`, so an armed row is always in that loop and
            // `outputs[job.id]` is always present. Allocating a second time from the same
            // `reserved` ledger would collide with the first pass's own entry and hand the row
            // `<name>-compressed-1.pdf`.
            let output = shipped?.url ?? outputs[job.id]
                ?? FileNaming.output(for: job.url, suffix: "compressed", folder: folder,
                                     reserving: &reserved)
            return RecompressPlan(
                id: job.id, url: job.url, target: chosen, output: output,
                temp: output.deletingLastPathComponent()
                    .appendingPathComponent(".toolbox-recompress-\(UUID().uuidString).pdf"),
                parked: versionStore.reservePreviousURL(for: job.url, reserving: &reserved),
                runnerUp: store.reserveURL(for: job.url, reserving: &reserved))
        }
```

- [ ] Add the phase runner and the per-row body. **Recorded disposition — the per-tick
      `Task { @MainActor in … }` in `recompress`'s `report` stays as written**, even though
      `ToolQueue.process`'s own `report` deliberately uses `DispatchQueue.main.async` and says why
      ("tasks carry no ordering guarantee, so two ticks could land swapped and walk the progress bar
      backwards; the main queue is FIFO"). The asymmetry is real and the choice here is deliberate:
      `ToolQueue`'s ticks feed `setState`, a per-job STATE MACHINE whose guard exists to stop a late
      tick resurrecting a `.done` job into `.running` — an ordering failure there strands a row for
      ever. These ticks feed `recompressProgress[id]`, a plain per-row fraction — read by the row's
      own overlay and summed into `runProgress`, and recomputed from the dictionary on every
      `publishJobs()`, so there is no state machine to strand: a swapped pair moves one row's
      fraction by a frame and the next tick corrects it. It also matches `rerunForSwitch`'s existing form in this same file, so
      changing it here alone would leave two shapes for one job. Noted against `ToolQueue`'s
      stricter FIFO choice; the mechanism is unchanged.

```swift
    /// The armed rows, through the engine directly. A sliding window of the same width as a normal
    /// batch, mirroring `ToolQueue.execute` — launch the next as each finishes, never add-all,
    /// which would ignore the cap.
    private func runRecompressPhase(_ plans: [RecompressPlan], engine: any Compressing) async {
        // The gate that makes Cancel work during phase 1. `queue.cancel()` cancels the queue's own
        // task and `queue.run` then returns NORMALLY, so without this the recompress phase would
        // start as though the cancel had never happened — and `recompressTask` is nil for the whole
        // of phase 1, which is why cancelling that alone cannot cover this window.
        guard !runCancelled, !plans.isEmpty else { return }
        let task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = plans.makeIterator()
                func launchNext() {
                    guard !Task.isCancelled, let plan = iterator.next() else { return }
                    group.addTask { await self?.recompress(plan, engine: engine) }
                }
                for _ in 0..<max(1, SystemInfo.performanceCoreCount) { launchNext() }
                while await group.next() != nil { launchNext() }
            }
        }
        recompressTask = task
        await task.value
        recompressTask = nil
    }

    private func recompress(_ plan: RecompressPlan, engine: any Compressing) async {
        let fm = FileManager.default
        // A recompress always reads the ORIGINAL input (D2 — never the compressed output), so a
        // missing original stops this row before it starts; its shipped result and versions stay
        // exactly as they are, and the rest of the batch is unaffected (R10).
        guard fm.fileExists(atPath: plan.url.path) else {
            recompressErrors[plan.id] = "The original file is no longer where it was"
            runCompleted.insert(plan.id)
            publishJobs()
            return
        }
        recompressProgress[plan.id] = 0
        publishJobs()
        let id = plan.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.recompressProgress[id] != nil else { return }
                self.recompressProgress[id] = fraction
                self.publishJobs()
            }
        }
        var capturedReport: MRCDocumentReport?
        do {
            let outcome = try await engine.compress(plan.url, preset: plan.target, to: plan.temp,
                                                    alternateOutput: plan.runnerUp,
                                                    mrcReport: { capturedReport = $0 },
                                                    progress: report)
            // The engine may return normally after its own final checkpoint (`CompressEngine`'s
            // last `Task.checkCancellation()` precedes the rename-and-return), so a cancel landing
            // in that window arrives here as a successful outcome — committing it would overwrite
            // the file the user already has, which is exactly what R9 forbids.
            try Task.checkCancellation()
            try commit(outcome, plan: plan, report: capturedReport)
        } catch is CancellationError {
            // Cancelled. On the throwing path the engine's atomic-write contract left no output;
            // on the post-checkpoint path its result exists at plan.temp (and, when the engine
            // produced one, its alternate at plan.runnerUp) — the two lines below remove both.
            // Nothing was committed either way,
            // so the row keeps its previous result (R9).
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
        } catch let stranded as RunnerUpStore.SwitchError {
            // MUST precede the generic catch. `shippedStranded` is the one failure where the
            // shipped file is NOT kept — it survives under a hidden dot-name nothing else looks
            // for — so "kept your X version" would be a flat lie about the user's own file.
            // Surface the store's message (it carries the park path) and drop the row's version
            // record, exactly as the switch path does: `reportSwitchFailure` sets
            // `switchFailures[id]`, and `versions(for:)` returns nil while that is set, so the row
            // stops advertising a delivered file it can no longer back (the F6 mislabel).
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
            reportSwitchFailure(plan.id, stranded.localizedDescription)
        } catch {
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
            // An explicit button press NEVER fails silently (R12), and the version they kept is
            // named so the message is actionable. Every error reaching here left the shipped file
            // exactly as it was — `promote`'s contract guarantees it for every throw except
            // `shippedStranded`, which the arm above already took.
            let kept = versionStore.versions(for: plan.id)?.shipped?.preset ?? plan.target
            recompressErrors[plan.id] = "Recompress failed — kept your \(kept.title) version"
        }
        recompressProgress[plan.id] = nil
        runCompleted.insert(plan.id)
        publishJobs()
    }

    /// R12/R13: land one recompress outcome. The version the user has is parked BEFORE the fresh
    /// result is promoted, so it survives every failure path; a no-gain commits nothing and clears
    /// nothing.
    private func commit(_ outcome: JobOutcome, plan: RecompressPlan,
                        report: MRCDocumentReport?) throws {
        let fm = FileManager.default
        // Both early returns below are unreachable by construction — a plan is only built for an
        // ARMED row, and `recompressState`'s own `guard let row = versions(for: job)` means a row
        // with no store entry never arms (a no-gain row DOES get an entry, with `shipped: nil`);
        // and `CompressEngine` never returns an OCR outcome — and both clean up anyway: an early
        // return that leaves the temp file and the runner-up
        // reservation behind would leak them for the session, and a "can't happen" is not a
        // reason to leak.
        guard let row = versionStore.versions(for: plan.id) else {
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
            return
        }
        let shippedBytes: Int
        let variant: EngineVariant
        var runnerUp: FileVersion?
        switch outcome {
        case .compressed(_, let after):
            shippedBytes = after
            variant = .plain
        case .compressedHeavy(let before, let after, let runnerUpBytes):
            shippedBytes = after
            variant = .mrc
            runnerUp = FileVersion(url: plan.runnerUp, bytes: runnerUpBytes, preset: plan.target,
                                   variant: runnerUpBytes == before ? .original : .plain)
        case .noGain:
            // Nothing was written, so there is nothing to commit — and nothing to clear. The
            // shipped version, its URL and its parked versions all stay (R12); the attempt is
            // recorded so re-selecting this preset shows the futile caption rather than re-running
            // a known-futile job (R6).
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
            futileAttempts.insert(FutileAttempt(id: plan.id, preset: plan.target))
            versionStore.recordAttempt(plan.target, for: plan.id)
            return
        case .ocrAdded, .alreadySearchable:
            // Never produced by CompressEngine — cleaned up regardless, as above.
            try? fm.removeItem(at: plan.temp)
            store.discard(plan.runnerUp)
            return
        }
        if let previouslyShipped = row.shipped {
            try store.promote(fresh: plan.temp, to: previouslyShipped.url, parking: plan.parked)
            // `promote` reaches the cache slot on a best-effort third step (see its doc): a
            // successful return does NOT guarantee a file exists at `plan.parked`. Recording the
            // slot regardless is correct and deliberate — a `previous` slot whose file has gone is
            // an already-designed-for state, handled by `useVersion`'s "That version is no longer
            // available — recompress at <preset> to get it back" path. Nothing below may assume
            // the parked file is on disk.
            // Replacing the previous slot discards the file the old occupant held (R14) — the cache
            // never accumulates superseded versions.
            versionStore.setSlot(.previous,
                                 to: FileVersion(url: plan.parked, bytes: previouslyShipped.bytes,
                                                 preset: previouslyShipped.preset,
                                                 variant: previouslyShipped.variant),
                                 for: plan.id)
            versionStore.setShipped(FileVersion(url: previouslyShipped.url, bytes: shippedBytes,
                                                preset: plan.target, variant: variant),
                                    for: plan.id)
        } else {
            // A row that shipped nothing has no version to park — the result simply takes the
            // freshly reserved output name.
            try fm.moveItem(at: plan.temp, to: plan.output)
            versionStore.setShipped(FileVersion(url: plan.output, bytes: shippedBytes,
                                                preset: plan.target, variant: variant),
                                    for: plan.id)
        }
        versionStore.setSlot(.runnerUp, to: runnerUp, for: plan.id)
        if runnerUp == nil { store.discard(plan.runnerUp) }
        if let report { rerunReports[plan.id] = report }
        // R13: a result larger than the version they had still ships — they chose the quality —
        // with honest sizes. The engine guarantees it is smaller than the ORIGINAL; anything else
        // came back `.noGain` above.
    }
```

- [ ] Give `recompressErrors` its full lifetime rule (R12). The message must stay authoritative
      for the run that produced it — a failed row RE-ARMS, because a failed attempt records no
      preset (R1), so a rule of "clear once the row is armed" would erase every failure message the
      instant it was written. It is cleared on exactly two events: the next run starts, and the
      user selects a different preset. Extend the existing `preset` observer:

```swift
    @Published var preset: CompressPreset = .balanced {
        didSet {
            guard preset != oldValue else { return }
            // Changing preset is the user saying "never mind that one, what about this?" — a
            // message about the previous target is now stale. Until they do, it stands, ARMED ROW
            // OR NOT: a failed attempt leaves the row armed at the same preset, and suppressing
            // the message there would mean an explicit button press failed silently.
            recompressErrors = [:]
            // Cleared BEFORE the reestimate, which is the only republish this observer needs:
            // `reestimatePendingJobs()`'s whole body is `publishJobs()`, so a trailing call would
            // publish the same state twice.
            reestimatePendingJobs()
        }
    }
```

- [ ] Have `compress()` run the phase after the queue's, and clear the per-run state at the
      start of a run (`recompressErrors = [:]`, `runCompleted = []`, `runCancelled = false`).
      Task 10 owns the run bookkeeping around it and writes that tail out in full; this task only
      needs `await runRecompressPhase(plans, engine: engine)` between `await queue.run { … }` and
      `isRunning = false`.
- [ ] Extend `cancel()` **in this task**, not in Task 10. The two cancel tests above are written
      here, so the mechanism they exercise must land here or this task's own gate is unreachable:
      `runCancelled = true` is what makes
      `testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase` pass, and
      `recompressTask?.cancel()` is what makes `try Task.checkCancellation()` throw in
      `testCancellingARecompressKeepsThePreviousResult`. Task 10 makes no further change to this
      function. The whole function as it stands after this task (Task 4's reclaim loop kept
      verbatim):

```swift
    func cancel() {
        // Set FIRST: `queue.cancel()` can let phase 1 return before the next line runs, and the
        // phase-2 guard reads this flag.
        runCancelled = true
        queue.cancel()          // unwinds the queue's own task
        recompressTask?.cancel()// unwinds recompresses already in flight
        // Discard the in-flight batch's runner-up reservations, except any the store has since
        // claimed as a committed version. A cancelled job returns to `.queued` and, by the engine's
        // atomic-write contract, leaves no partial output — so this only reclaims files a
        // completed-but-superseded job wrote before the cancel landed (R18).
        for (id, url) in runReservations where versionStore.versions(for: id)?.runnerUp?.url != url {
            store.discard(url)
        }
        runReservations = [:]
    }
```

- [ ] Run the suite; all green.
- [ ] Commit: `feat(compress): recompress armed rows through the engine with a parking commit`

---

### Task 10: One run, two phases

**Model:** opus · **Track:** E

Resolves the spec's Risk 2. Queued rows and armed rows form ONE run behind one button, one progress
bar and one cancel — and the two mechanisms are **serialised**, never concurrent, so total
concurrency is bounded by one normal batch width *by construction* rather than by argument.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `runRecompressPhase`, `armedJobs`, `queue.run`
- Produces: `@Published private(set) var runIDs: [ToolJob.ID]`, `var runTotalCount: Int`,
  `var runFinishedCount: Int`, `var runProgress: Double`, `var pendingCount: Int`

**Steps**

- [ ] FIRST, before any test below is written or run: make the shared `Gate` test double
      multi-waiter. Every gated test written so far suspends exactly ONE engine call behind the
      latch, so a single stored continuation has been sufficient; `testRunProgressIsScopedToTheRunsOwnRows`
      below is the first to put TWO jobs behind it at once (phase 2 launches up to
      `performanceCoreCount` children), and the second waiter would overwrite and orphan the
      first — the test would hang rather than fail, and this task's own mandated `tests` gate
      would be unreachable. Replace the existing `private actor Gate` in
      `Tests/ToolboxTests/CompressViewModelTests.swift` with:

```swift
    /// A latch, not a handoff: phase 2 runs up to `performanceCoreCount` recompresses at once, so
    /// two engine calls can be suspended here simultaneously. A single stored continuation would
    /// let the second waiter overwrite (and orphan) the first.
    private actor Gate {
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            opened = true
            for continuation in continuations { continuation.resume() }
            continuations = []
        }
    }
```

      This touches a test HELPER, not an assertion, so Task 4's binding constraint — adjust only
      the accessor, never the expected value — is not in tension: no existing test's behaviour
      changes, because every one of them is a single waiter and the single-waiter path through
      this actor is identical.
- [ ] Write the failing tests:

```swift
    // MARK: one run, two phases (R5/R9)

    /// R5: newly added files and armed rows form ONE run behind one button. The counts the button
    /// is titled from must see both sets.
    func testMixedRunCountsBothSets() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.armedCount, 0)

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        XCTAssertEqual(model.pendingCount, 1, "only queued: the button reads Compress")
        XCTAssertEqual(model.armedCount, 0)

        model.preset = .smallestSize
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.armedCount, 1, "both sets: the button reads Compress K · Recompress M")
        XCTAssertTrue(model.canCompress)
    }

    /// The armed set alone is enough to arm the button — with nothing queued, "Recompress N PDFs"
    /// must still be pressable.
    func testArmedRowsAloneEnableTheButton() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        XCTAssertFalse(model.canCompress)

        model.preset = .smallestSize
        XCTAssertTrue(model.canCompress)
    }

    /// Risk 2's resolution, asserted: the recompress phase does not start until the queue phase is
    /// done, so the two mechanisms never run at once and the batch width is never doubled.
    func testTheRecompressPhaseWaitsForTheQueuePhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The queued job is suspended in the engine. The armed row must not have started.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must wait for the queue phase to finish")

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
        XCTAssertEqual(env.stub.callCount, callsBefore + 2)
    }

    /// R9's progress bar is scoped to THIS run's rows: a recompress of one row among several
    /// finished ones opens at zero, not at "already mostly done".
    func testRunProgressIsScopedToTheRunsOwnRows() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input, try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        let armed = model.armedCount
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        XCTAssertEqual(model.runTotalCount, armed, "the denominator is this run's rows only")
        XCTAssertEqual(model.runFinishedCount, 0, "nothing in this run has finished yet")
        XCTAssertLessThan(model.runProgress, 1.0)

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }
```

- [ ] Run and watch them fail.
- [ ] Implement in `CompressViewModel`:

```swift
    /// The rows of the run currently in flight — queued and armed alike. The progress bar's
    /// denominator: a recompress of 2 rows among 5 finished ones must open at 0%, not 60%.
    @Published private(set) var runIDs: [ToolJob.ID] = []
    // `runCompleted` is declared in Task 9, where its first writer lives — do NOT re-declare it
    // here; this task only reads it and adds the queue-phase writer below.

    /// What the run in flight is made of, captured at its start. Arming is suppressed for the
    /// duration of a run, so the composition cannot be re-derived once it is under way — and the
    /// progress bar's verb ("Compressing" vs "Recompressing") depends on it.
    struct RunComposition: Equatable {
        let queued: Int
        let armed: Int
    }
    @Published private(set) var runComposition = RunComposition(queued: 0, armed: 0)

    var runTotalCount: Int { runIDs.count }
    var runFinishedCount: Int { runCompleted.count }

    var runProgress: Double {
        guard !runIDs.isEmpty else { return 0 }
        var total = Double(runCompleted.count)
        for job in jobs where runIDs.contains(job.id) && !runCompleted.contains(job.id) {
            if case .running(let fraction) = job.state { total += fraction }
        }
        return total / Double(runIDs.count)
    }

    /// Rows waiting to be compressed for the first time (R5's K).
    var pendingCount: Int {
        jobs.filter { job in
            switch job.state {
            case .queued, .analysing: return true
            case .running, .done, .failed: return false
            }
        }.count
    }

    var canCompress: Bool { engine != nil && !isRunning && (hasQueuedWork || armedCount > 0) }
```

      and rewrite `compress()` — the WHOLE function, once, in final form. Tasks 9 and 10 both add
      to it, so it is written out here complete rather than as two overlapping patches:

```swift
    func compress() {
        guard let engine, !isRunning else { return }
        let chosen = preset
        let folder = outputFolder
        // Allocate every output name up front, serially, on this thread — BEFORE the concurrent
        // run starts — so two same-basename inputs from different folders can't both claim the
        // same target and fail the second job's atomic rename (a purely on-disk check races under
        // concurrency). Each job then looks up its pre-reserved, guaranteed-unique destination.
        var reserved = Set<String>()
        // Seed every row's EXISTING result path before allocating anything. A recompress commit
        // parks then promotes, so its file is transiently absent — a queued same-basename job must
        // be kept off that path by the reservation, never by the file happening to exist now (R11).
        for job in queue.jobs {
            if let shipped = versionStore.versions(for: job.id)?.shipped {
                reserved.insert(FileNaming.reservationKey(for: shipped.url))
            }
        }
        var outputs: [ToolJob.ID: URL] = [:]
        var alternates: [ToolJob.ID: URL] = [:]
        for job in queue.jobs {
            outputs[job.id] = FileNaming.output(for: job.url, suffix: "compressed",
                                                folder: folder, reserving: &reserved)
            // Runner-up name from the same serial allocator, into the cache root (C4/R15). Only a
            // `.compressedHeavy` job actually writes this file; the rest just hold the reservation.
            alternates[job.id] = store.reserveURL(for: job.url, reserving: &reserved)
            // Only for the rows this batch will actually run: `ToolQueue.execute` picks up
            // `.queued` jobs only, so recording the current preset against a finished row from an
            // earlier batch would misattribute it. (The reservations above stay unfiltered: a
            // finished row still owns its output and runner-up paths, and this batch must not hand
            // either to a new same-basename job.)
            if isStillQueued(job) { pendingPresets[job.id] = chosen }
        }
        // `armedJobs` is read BEFORE `isRunning` goes true: arming is suppressed for the duration
        // of a run (R9), so the set must be captured while it still exists.
        let armed = armedJobs
        let plans: [RecompressPlan] = armed.map { job in
            let shipped = versionStore.versions(for: job.id)?.shipped
            // R11: the row's own result path, even if "Save to" changed since. A row that shipped
            // nothing (no-gain) has none, so it takes the name the loop above ALREADY allocated for
            // it — `jobs` is a 1:1 map of `queue.jobs`, so an armed row is always in that loop and
            // `outputs[job.id]` is always present. Allocating a second time from the same
            // `reserved` ledger would collide with the first pass's own entry and hand the row
            // `<name>-compressed-1.pdf`.
            let output = shipped?.url ?? outputs[job.id]
                ?? FileNaming.output(for: job.url, suffix: "compressed", folder: folder,
                                     reserving: &reserved)
            return RecompressPlan(
                id: job.id, url: job.url, target: chosen, output: output,
                temp: output.deletingLastPathComponent()
                    .appendingPathComponent(".toolbox-recompress-\(UUID().uuidString).pdf"),
                parked: versionStore.reservePreviousURL(for: job.url, reserving: &reserved),
                runnerUp: store.reserveURL(for: job.url, reserving: &reserved))
        }

        let queuedIDs = queue.jobs.filter(isStillQueued).map(\.id)
        runIDs = queuedIDs + plans.map(\.id)
        // The queued subset is tracked separately: see `runQueuedIDs`. An armed row is `.done`
        // throughout, so only `recompress` may mark one finished.
        runQueuedIDs = Set(queuedIDs)
        runComposition = RunComposition(queued: queuedIDs.count, armed: plans.count)
        runCompleted = []
        // Cleared at the START of the run, never at the end: a message must survive the run that
        // produced it, and only the NEXT run (or a preset change) makes it stale.
        recompressErrors = [:]
        runCancelled = false
        runReservations = alternates
        isRunning = true
        Task {
            // Phase 1 — the queued rows, through the shared queue exactly as before.
            await queue.run { job, report in
                // A missing reservation means `add` let a file into the batch after the up-front
                // allocation pass — fail this one job loudly rather than silently allocating a
                // second, racing name from inside the concurrent run.
                guard let output = outputs[job.id] else { throw MissingOutputReservationError() }
                let alternate = alternates[job.id]
                // Captured here, per job invocation, so each concurrent job's report lands on that
                // job's own `JobResult` rather than a shared/racing variable.
                var capturedReport: MRCDocumentReport?
                let outcome = try await engine.compress(job.url, preset: chosen, to: output,
                                                        alternateOutput: alternate,
                                                        mrcReport: { capturedReport = $0 }) { report($0) }
                switch outcome {
                // `.noGain` deliberately writes nothing, so there is no output file to point at.
                case .noGain:
                    return JobResult(outcome, mrcReport: capturedReport)
                // The heavy result retains the plain-gs version as the runner-up for the switch.
                case .compressedHeavy:
                    return JobResult(outcome, outputURL: output, alternateURL: alternate,
                                     mrcReport: capturedReport)
                default:
                    return JobResult(outcome, outputURL: output, mrcReport: capturedReport)
                }
            }
            // Phase 2 — the armed rows, through the engine directly. SERIALISED after phase 1, not
            // alongside it: running both mechanisms at once would put 2 × the batch width of gs
            // processes on the machine, and the spec bounds the total to one normal batch. One
            // button, one bar, one cancel — and the bound holds by construction (Risk 2).
            // `runRecompressPhase` opens with the `runCancelled` guard, which is what makes a
            // cancel landing during phase 1 stop the run here instead of starting phase 2.
            await runRecompressPhase(plans, engine: engine)
            // The batch is over: its in-flight reservations are settled (every committed runner-up
            // is now owned by `versionStore`), so nothing here is `cancel`'s to discard any more.
            runReservations = [:]
            runIDs = []
            runQueuedIDs = []
            runComposition = RunComposition(queued: 0, armed: 0)
            isRunning = false
        }
    }
```

- [ ] Record queue-phase completions into `runCompleted` **from the `queue.$jobs` sink, not from
      `ingestCompletedJobs`'s switch**. `ingestCompletedJobs` handles `.done` only — by design, a
      `.failed` job has no outcome to record — so recording there would never count a failed row
      and the run bar would stall permanently one row short of 1 on any batch with a failure.
      Terminal means `.done` OR `.failed`, which is a property of the row's state, not of its
      outcome. Add beside the ingest call in the sink, before `publishJobs()`:

```swift
    /// This run's QUEUED rows. Deliberately NOT `runIDs`, which also holds the armed rows: an
    /// armed row is `.done` from beginning to end (R8), so a state-driven sweep over `runIDs`
    /// would count every armed row as finished on the first emission after the run started — a
    /// 1-queued + 1-armed run would open its bar at 50%, the exact failure `runIDs` exists to
    /// prevent. Armed rows are recorded by `recompress` itself, the only thing that knows when
    /// one has genuinely finished.
    private var runQueuedIDs: Set<ToolJob.ID> = []

    /// Every QUEUED row of this run that has reached a terminal state. Separate from
    /// `ingestCompletedJobs` on purpose: that path is outcome-driven and `.failed` carries no
    /// outcome, so a failure would never be counted and the bar would stall for ever one row
    /// short of 1. Membership is also what keeps rows finished by an EARLIER batch out — they are
    /// `.done` too, and counting them would push `runFinishedCount` past `runIDs.count`.
    private func recordTerminalRunRows() {
        for job in rawJobs where runQueuedIDs.contains(job.id) {
            switch job.state {
            case .done, .failed: runCompleted.insert(job.id)
            case .queued, .analysing, .running: continue
            }
        }
    }
```

- [ ] No change to `cancel()` in this task: Task 9 already wrote the two mechanisms that actually
      stop both phases — `runCancelled = true`, `queue.cancel()` and `recompressTask?.cancel()` —
      per `runCancelled`'s doc comment there, and there is no `runTask` left to layer a third,
      dead cancel onto. The function stands as Task 9 left it:

```swift
    func cancel() {
        // Set FIRST: `queue.cancel()` can let phase 1 return before the next line runs, and
        // the phase-2 guard reads this flag.
        runCancelled = true
        queue.cancel()          // unwinds the queue's own task
        recompressTask?.cancel()// unwinds recompresses already in flight
        // Discard the in-flight batch's runner-up reservations, except any the store has since
        // claimed as a committed version. A cancelled job returns to `.queued` and, by the engine's
        // atomic-write contract, leaves no partial output — so this only reclaims files a
        // completed-but-superseded job wrote before the cancel landed (R18).
        for (id, url) in runReservations where versionStore.versions(for: id)?.runnerUp?.url != url {
            store.discard(url)
        }
        runReservations = [:]
    }
```

- [ ] **Update `testLaterBatchDoesNotRewriteAFinishedRowsPreset` — the one existing test this
      task's `compress()` semantics break.** Today the test's second batch runs at `.balanced` with
      a `.smallestSize`-finished row in the list. Before this feature that row was inert; after it,
      the row ARMS (`rowPreset .smallestSize` ≠ selected `.balanced`) and phase 2 recompresses it —
      so by the time the test reaches its switch, `setSlot` has discarded the old runner-up file,
      `removeItem(at: job.alternateURL)` throws, and `switchVersion` takes the instant branch
      against the NEW runner-up, so `waitUntil` never sees the engine call it is waiting for and
      times out. Task 10's "all green" and Task 13's mandated test gate are unreachable until this
      is fixed.

      The fix is **intent-preserving**: run the second batch at the finished row's OWN preset, so
      the row stays disarmed for the duration (`recompressState` returns `.none` on
      `row.rowPreset == target`, ahead of everything but the futile check), and move the preset
      change to AFTER the batch. The row is then armed but never run, its runner-up survives, the
      switch still finds it missing and still re-runs — and the discriminator still discriminates
      (stronger than the ORIGINAL test would be under the new semantics, where the row would have
      been recompressed to `.balanced` and the distinction destroyed): the selected preset at
      switch time is `.balanced` while the row's own is `.smallestSize`, so a re-run that wrongly
      used the CURRENT preset would append `.balanced` and fail the assertion. Task 4's binding constraint is a constraint on the ASSERTION, and the
      assertion survives verbatim, including its message.

      The name still earns itself and no coverage is lost, though the shape moves: under this
      feature "a later batch at a different preset" is no longer an inert list change — it IS a
      recompress, and it is covered as one by this task's own `testMixedRunCountsBothSets` and
      `testTheRecompressPhaseWaitsForTheQueuePhase`. What this test uniquely pins is the surviving
      invariant its name states: a row's recorded preset is the row's own, and anything that
      regenerates that row must use it rather than whatever is selected now. The full updated test:

```swift
    func testLaterBatchDoesNotRewriteAFinishedRowsPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .smallestSize
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        // A second file joins the list alongside the finished row. The batch runs at the finished
        // row's OWN preset, which leaves that row disarmed (R3) — so this run is a pure queue
        // batch and the finished row's parked runner-up is untouched by it.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        // NOW the user selects a different preset. Both rows arm, but nothing runs: arming changes
        // nothing until the button (D1), so the first row still holds the pair its own batch made.
        model.preset = .balanced

        // The first row's runner-up vanishes, so switching it honestly re-runs the job — which
        // must go through the engine at the preset that row was compressed at.
        let job = try XCTUnwrap(model.jobs.first { $0.url == env.input })
        try FileManager.default.removeItem(at: try XCTUnwrap(job.alternateURL))
        let callsBefore = env.stub.callCount

        model.switchVersion(for: job)
        try await waitUntil(timeout: 5) {
            env.stub.callCount > callsBefore && !model.isSwitchRerunning.contains(job.id)
        }

        XCTAssertEqual(env.stub.presets.last, .smallestSize,
                       "the re-run must reproduce the row's own output, not the current preset")
    }
```

- [ ] **Audit the rest of the existing suite against the same semantics change** — a behaviour
      change to a shared entry point is a diff on every existing test that calls it. A test is
      AFFECTED only if a finished row's recorded preset differs from the selected preset at a
      SECOND `compress()`; anything else never reaches phase 2. Produced by grepping every
      `model.compress()` call in `CompressViewModelTests.swift` and attributing each to its test:

      | Test | `compress()` calls | Outcome |
      |---|---|---|
      | `testAddIsIgnoredWhileABatchIsRunning` | 1 | unaffected — no finished row exists when it runs |
      | `testThreeFileSyntheticBatchCompressesEndToEnd` | 1 | unaffected |
      | `testCompressedHeavyOutcomePublishesHeavyVersions` | 1 | unaffected |
      | `testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize` | 1 | unaffected |
      | `testCompressedHeavyRetainsMRCReportOnJob` | 1 | unaffected |
      | `testSwitchTogglesInstantlyAndReversibly` | 1 | unaffected |
      | `testCapsuleTitleFlipsOnSwitch` | 1 | unaffected |
      | `testCapsuleTitleReadsOriginalWhenRunnerUpIsInput` | 1 | unaffected |
      | `testSavedBytesUsesShippedVersionForHeavyJob` | 1 | unaffected |
      | `testDisplayedBytesTracksShippedVersion` | 1 | unaffected |
      | `testSwitchWithMissingRunnerUpRerunsJob` | 1 | unaffected — its second engine call comes from `rerunForSwitch`, not from `compress()` |
      | `testSwitchFailingAfterRerunLeavesStateCanonical` | 1 | unaffected — same, via the re-run |
      | `testLaterBatchDoesNotRewriteAFinishedRowsPreset` | **2** | **AFFECTED** — rewritten in the step above |
      | `testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling` | 1 | unaffected |
      | `testRemoveRowDiscardsRunnerUp` | 1 | unaffected |
      | `testClearFinishedDiscardsRunnerUps` | 1 | unaffected |
      | `testCancelDiscardsRunnerUpReservations` | 1 | unaffected |

      Exactly one existing test calls `compress()` twice, and it is the one rewritten above. The
      new tests this plan adds are written against the new semantics from the start and are not in
      scope here.
- [ ] Run the suite; all green.
- [ ] Commit: `feat(compress): run queued and armed rows as one serialised batch`

---

# Phase 3 — integration (Tasks 11–13)

Both Phase-2 tracks are merged into the feature branch and the suite is green before Task 11 starts.

### Task 11: Model-side completion — armed rows are not "all finished"

**Model:** opus · **Track:** serial (Phase 3)

One aggregate the view depends on that only the model can express, plus the cache-lifecycle and
capsule regressions R20 asks for, plus the two members introduced elsewhere whose only consumers are
private to a `View` and so unreachable from the test bundle — `armedSummary`'s arithmetic (Task 8)
and `useVersion(.previous,…)` end to end (Task 4). Both are asserted here, at the model, for the
same reason Task 12's lead-derivation tests are: an untestable consumer is the argument FOR a
model-level test, not against one. This task adds no new implementation for either — the code under
test already landed in Tasks 4 and 8.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Produces:
  - `var allFinished: Bool` (now false while any row is armed)
- Consumes: `CompressViewModel.RunComposition` / `runComposition` — declared and maintained by
  Task 10, which owns the run bookkeeping. Nothing here re-declares it. Also `armedSummary` /
  `ArmedSummary`, `recompressPrediction(for:at:)` and `analysis(for:)` (Task 8), `useVersion(_:for:)`
  and `recompressErrors` (Task 4), and the test-side `HeavyEnv(before:contentType:)` seam (Task 8) —
  all consumed by the tests above, none re-declared here.

**Steps**

- [ ] Write the tests. **Not all of them fail first, and that is the point of siting them here:**
      only `testAllFinishedIsFalseWhileARowIsArmed` exercises this task's own change and fails
      before it. The other seven are regressions over behaviour that already landed in Phase 1 and
      Phase 2 — the cache lifecycle, the capsule on a plain row, `armedSummary`'s arithmetic and
      `useVersion(.previous,…)` — whose only production consumers are private to a `View` and so
      unreachable from the test bundle. They belong on the MERGED branch, which is the first point
      at which the store, the arming state, the prediction and the recompress commit all exist
      together to be asserted against.

```swift
    // MARK: armed-state aggregates and cache lifecycle (R4/R17/R18)

    /// R4 hides the success banner and the "Reveal in Finder" / "Compress More" affordances while
    /// anything is armed — all three hang off `allFinished`, which must therefore stop being true.
    func testAllFinishedIsFalseWhileARowIsArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        XCTAssertTrue(model.allFinished)

        model.preset = .smallestSize
        XCTAssertFalse(model.allFinished, "an armed row means the batch is not finished")

        model.preset = .balanced
        XCTAssertTrue(model.allFinished, "disarming restores the finished state exactly")
    }

    /// R18/D6: "Clear finished" discards the cleared rows' parked files — the previous version
    /// included, not just the runner-up.
    func testClearFinishedDiscardsTheParkedPreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let previous = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.previous?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))

        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path),
                       "the parked previous version must go with the row")
    }

    /// R15: the capsule renders on ANY row with two or more versions — including a plain
    /// (non-heavy) result that gained a previous version from a recompress.
    func testAPlainResultWithAPreviousVersionOffersTheCapsule() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        // A Maximum-quality re-run that comes back plain gs — no runner-up at all.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 2_000),
                                          shippedBytes: 2_000, runnerUpBytes: nil) }
        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))
        XCTAssertNil(row.runnerUp, "the re-run shipped plain gs, so there is no runner-up")
        XCTAssertEqual(row.count, 2, "current + previous still draws the capsule")
        XCTAssertEqual(row.capsuleTitle, "Versions")
    }

    // MARK: the armed banner's arithmetic (R4)

    /// `armedSummary.extraSaving` is the banner's only number and Task 8's prediction feeds it, so
    /// all three of its branches are pinned here — the untestable consumer (`armedDetail`, private
    /// to a `View`) is the argument FOR asserting at the model, not against asserting at all.
    /// Branch 1: a confident armed row moving to a smaller preset contributes a positive extra.
    func testArmedSummarySumsThePredictedExtraSaving() async throws {
        // Task 8's proven confident pair: `.scanColour` shipped MRC at Balanced and armed at
        // Smallest Size keeps `targetWantsMRC == shippedWasMRC == true`, so the calibration branch
        // runs and a confident number exists.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        // The premise, measured rather than assumed: the sign of `extraSaving` is the sign of
        // `balanced - smallest` in the estimator's own figures, because the prediction is the
        // shipped size scaled by that ratio.
        XCTAssertLessThan(try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes),
                          try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes),
                          "the estimator must rate Smallest Size below Balanced for this row")

        // Read the prediction back rather than recomputing it: `Int(_:)` truncates, and a
        // differently bracketed expression of the same real number lands a byte away.
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1)
        XCTAssertEqual(summary.queuedCount, 0)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertGreaterThan(try XCTUnwrap(summary.extraSaving), 0,
                             "the banner reads \u{2248} saves another N")
    }

    /// Branch 2: moving UP in quality predicts a bigger file, so the extra is zero or negative —
    /// the banner must be able to say "files may grow for the extra quality" rather than show a
    /// negative saving. The row is shipped at Smallest Size and armed at Balanced, the same
    /// repeating-path pair in reverse, over a large original so the "must beat the original" guard
    /// cannot suppress the prediction and send this test down the nil branch instead.
    func testArmedSummaryGoesNonPositiveWhenTheArmedPresetIsLessAggressive() async throws {
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .smallestSize
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .balanced),
                                      "the prediction must exist, or this asserts the nil branch")
        XCTAssertGreaterThan(predicted, HeavyEnv.heavyBytes,
                             "Balanced is rated above Smallest Size, so the scaled figure grows")
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary.extraSaving), 0)
    }

    /// Branch 3: no armed row has a confident prediction ⇒ `extraSaving` is nil, so the banner
    /// shows no detail line rather than a fabricated zero. `armedCount` is asserted alongside it,
    /// or "nil because there is no summary at all" would pass for the wrong reason.
    func testArmedSummaryWithholdsTheExtraWhenNoRowPredictsConfidently() async throws {
        // Task 8's proven no-confident-prediction pair: `.bornDigital` is never MRC-eligible while
        // `HeavyEnv` always ships MRC, so the raw multi-megabyte estimate is used and the "must
        // beat the original" guard fires against the 1 kB original.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .maximumQuality
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1, "the row IS armed — the number is what is missing")
        XCTAssertNil(summary.extraSaving)
    }

    // MARK: the previous version, end to end (R7/R15)

    /// R7's third card: "Use this" on the PREVIOUS version swaps the delivered file back, records
    /// and all. The whole point of parking it is that this costs no engine call, so the engine must
    /// not be entered — and the file on disk must actually change, not just the record describing it.
    func testUsingThePreviousVersionSwapsTheDeliveredFileBack() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        var job = try XCTUnwrap(model.jobs.first)
        var row = try XCTUnwrap(model.versions(for: job))
        let deliveredURL = try XCTUnwrap(row.shipped?.url)
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(row.previous?.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(row.previous?.preset, .balanced)
        XCTAssertEqual(try fileSize(deliveredURL), 700)
        let callsBefore = env.stub.callCount

        model.useVersion(.previous, for: job)

        job = try XCTUnwrap(model.jobs.first)
        row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(env.stub.callCount, callsBefore, "an instant switch enters no engine")
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.heavyBytes, "the previous version is shipped")
        XCTAssertEqual(row.shipped?.preset, .balanced)
        XCTAssertEqual(row.previous?.bytes, 700, "…and the Smallest result takes the previous slot")
        XCTAssertEqual(row.previous?.preset, .smallestSize)
        XCTAssertEqual(row.shipped?.url, deliveredURL, "the delivered path is stable across a switch")
        // The record is not the proof: the user's own file at that path must now hold the other
        // version's content.
        XCTAssertEqual(try fileSize(deliveredURL), HeavyEnv.heavyBytes)
    }

    /// A vanished PREVIOUS version can never be regenerated (a re-run reproduces the row's own
    /// preset, not the previous one), so it must say so beside the row and drop the slot — while
    /// leaving the perfectly good delivered result exactly where it is.
    func testUsingAVanishedPreviousVersionReportsItAndDropsTheSlot() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let previous = try XCTUnwrap(model.versions(for: job)?.previous?.url)
        try FileManager.default.removeItem(at: previous)
        let callsBefore = env.stub.callCount

        model.useVersion(.previous, for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore, "a vanished previous is never re-run")
        XCTAssertNil(model.versions(for: job)?.previous, "the slot is dropped, not left dangling")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "That version is no longer available — recompress at "
                       + "\(CompressPreset.balanced.title) to get it back.")
        XCTAssertEqual(model.versions(for: job)?.shipped?.bytes, 700,
                       "a message beside the row, never a failure that hides a good result")
    }
```

- [ ] Run them. `testAllFinishedIsFalseWhileARowIsArmed` must FAIL (its `armedCount` guard is added
      below); the other seven must PASS on the merged branch. A red one among those seven is a
      genuine regression in Phase 1 or Phase 2 work, not a missing implementation here — diagnose
      it before writing a line of the step below.
- [ ] Implement:

```swift
    /// True only when every row has finished AND nothing is armed: an armed row is pending work,
    /// so the success banner, "Reveal in Finder" and "Compress More" must all stand down (R4).
    var allFinished: Bool {
        guard !jobs.isEmpty, !isRunning, armedCount == 0 else { return false }
        return jobs.allSatisfy { job in
            switch job.state {
            case .done, .failed: return true
            case .queued, .analysing, .running: return false
            }
        }
    }
```

      `runComposition` needs nothing here: Task 10 declares it and already sets it in `compress()`
      beside `runIDs` and resets it to `(0, 0)` where `runIDs` is cleared. This task's only change
      is `allFinished`.
- [ ] Run the suite; all green.
- [ ] Commit: `fix(compress): treat armed rows as pending work in the finished aggregates`

---

### Task 12: Wire the view

**Model:** opus · **Track:** serial (Phase 3)

The R17 aggregator sweep, enumerated. Every display that derived from `job.state`/`JobOutcome` now
derives from the version store, and the armed/running/finished chrome follows the run.

**Files**
- Modify: `Sources/Toolbox/Compress/CompressView.swift`
- Modify: `.claude/specs/20260725-recompress-quality-evidence/recompress-ux-mockup.html`
- Test: `Tests/ToolboxTests/CompressViewModelTests.swift`

**Interfaces**
- Consumes: `CompressViewModel.{versions,recompressState,recompressPrediction,isOriginalMissing,recompressErrors,armedSummary,armedCount,pendingCount,runProgress,runFinishedCount,runTotalCount,runComposition,allFinished,useVersion}`,
  `FileRow.{Lead,lead,onLeadTap,metaAccent}`, `SuccessBanner.tone`, `VersionsPopover`

**Steps**

- [ ] Rewrite `status(for:)`'s `.done` arm to read the store rather than the outcome shape, so a
      recompressed no-gain row shows its delivered file and any row with ≥2 versions draws the
      capsule (R15):

```swift
        case .done:
            // The version store, not the outcome shape, decides what a finished row shows: a
            // recompressed no-gain row keeps its `.done(.noGain)` outcome while genuinely shipping
            // a file, and a plain gs re-run of a heavy row still has two versions to offer (R15).
            guard let row = model.versions(for: job), let shipped = row.shipped else {
                return .unchanged("Already optimised")
            }
            return row.count > 1
                ? .doneHeavy(originalBytes: row.originalBytes, newBytes: shipped.bytes)
                : .done(originalBytes: row.originalBytes, newBytes: shipped.bytes)
```

- [ ] Add the row's lead and accent caption, and pass them plus the capsule title into `FileRow`:

```swift
    /// The leading item of a finished row's cluster.
    ///
    /// Decided deliberately: a recompress message is the outcome of a button the user pressed, so
    /// it outranks a plain finished row and survives until the next run clears it — but an ARMED
    /// preview supersedes it, because the user has moved on and asking "what would this preset
    /// give me?" must be answerable while last attempt's message is still notionally live.
    private func lead(for job: ToolJob) -> FileRow.Lead? {
        let state = model.recompressState(for: job)
        // R10, at arming time: an armed row whose ORIGINAL has gone cannot be recompressed at all,
        // so it must say so rather than show a confident pill promising a size nothing can produce.
        // Ahead of everything, because it invalidates the armed claim itself.
        if case .armed = state, model.isOriginalMissing(for: job) {
            return .error("The original file is no longer where it was")
        }
        // An error OUTRANKS the armed pill — unconditionally, not only when the row is disarmed.
        // A failed recompress records no preset (R1), so the row RE-ARMS the instant the attempt
        // fails; the old `state == .none` guard therefore suppressed R12's message on exactly the
        // rows that had just failed, and an explicit button press would have failed silently. The
        // message stays authoritative until the user changes preset or the next run starts — both
        // of which clear `recompressErrors` at source, so no guard is needed here.
        if let message = model.recompressErrors[job.id] { return .error(message) }
        switch state {
        case .armed(let target):
            guard let predicted = model.recompressPrediction(for: job, at: target) else {
                return .accentPill("→ may not shrink")
            }
            // The "≈" marker stays throughout: the figure is approximate however it was derived
            // (R16), so this never borrows the queued row's "~" fallback marker.
            return .accentPill("→ \u{2248}\(byteString(predicted))")
        case .futile(let target):
            return .neutralPill("No saving at \(target.title)")
        case .instantSwitch:
            return .link("Switch instantly")
        case .none:
            return nil
        }
    }

    private func metaAccent(for job: ToolJob) -> String? {
        switch model.recompressState(for: job) {
        case .armed(let target):
            // A row that has shipped nothing is being TRIED at the new preset, not re-shipped.
            return model.versions(for: job)?.shipped == nil
                ? "will try \(target.title)"
                : "will recompress at \(target.title)"
        case .instantSwitch(let target):
            return "your \(target.title) version is kept"
        case .futile, .none:
            return nil
        }
    }
```

      with the `FileRow(...)` call gaining
      `lead: lead(for: job)`, `onLeadTap: { model.useVersion(.previous, for: job) }`,
      `metaAccent: metaAccent(for: job)`, and
      `heavyCapsuleTitle: model.versions(for: job)?.capsuleTitle ?? "Heavy compression"`.
- [ ] Replace the banner/footer chrome:

```swift
                if model.isRunning {
                    runningBar
                } else if let summary = model.armedSummary {
                    SuccessBanner(headline: armedHeadline(summary),
                                  detail: armedDetail(summary),
                                  tone: .accent)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if model.allFinished {
                    SuccessBanner(headline: savedHeadline, detail: savedDetail)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
```

```swift
    /// Both fixed regions carry the story, because armed rows can be scrolled out of sight (R4).
    private func armedHeadline(_ summary: CompressViewModel.ArmedSummary) -> String {
        if summary.queuedCount > 0 {
            return "Will compress \(summary.queuedCount) and recompress \(summary.armedCount) PDFs"
        }
        let n = summary.armedCount
        return "Will recompress \(n) PDF\(n == 1 ? "" : "s") at \(model.preset.title)"
    }

    /// Summed over armed rows with a confident prediction only; nil when none has one, so the
    /// banner shows no detail line rather than a fabricated zero (R4).
    private func armedDetail(_ summary: CompressViewModel.ArmedSummary) -> String? {
        guard let extra = summary.extraSaving else { return nil }
        return extra > 0 ? "\u{2248} saves another \(byteString(extra))"
                         : "files may grow for the extra quality"
    }

    private var actionTitle: String {
        let queued = model.pendingCount, armed = model.armedCount
        if queued > 0, armed > 0 { return "Compress \(queued) · Recompress \(armed)" }
        if armed > 0 { return "Recompress \(armed) PDF\(armed == 1 ? "" : "s")" }
        return queued > 0 ? "Compress \(queued) PDF\(queued == 1 ? "" : "s")" : "Compress"
    }
```

- [ ] Scope the progress chrome to the run (R9), deleting `overallProgress`, the view's own
      `pendingCount` and the run half of `finishedCount`:

```swift
    private var runningBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            LinearProgress(fraction: model.runProgress)
            Text(batchProgressText(runVerb, finished: model.runFinishedCount,
                                   total: model.runTotalCount))
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize()
            LinkButton(title: "Cancel") { model.cancel() }
        }
    }

    /// "Recompressing" only when the run is nothing but armed rows; a mixed run is a compress run
    /// with recompression in it, and one bar cannot say both.
    private var runVerb: String {
        model.runComposition.queued == 0 && model.runComposition.armed > 0
            ? "Recompressing" : "Compressing"
    }
```

      with `footerNote` using the same `batchProgressText(runVerb, finished: model.runFinishedCount,
      total: model.runTotalCount)` while running, and `hasFinishedJobs` keeping its own whole-list
      count (it drives "Clear finished", which is not run-scoped).
- [ ] Point the version-derived aggregates at the store (R17):

```swift
    /// Open the shipped version if one exists, otherwise the original. The STORE is asked first: a
    /// recompressed no-gain row has a delivered file while the queue's `resultURL` is still nil.
    /// (OCR's own `resultURL ?? url` path is untouched — R19.)
    private func open(_ job: ToolJob) {
        NSWorkspace.shared.open(model.versions(for: job)?.shipped?.url ?? job.resultURL ?? job.url)
    }

    private func revealOutputs() {
        let outputs = model.jobs.compactMap { model.versions(for: $0)?.shipped?.url ?? $0.resultURL }
        let urls = outputs.isEmpty ? model.jobs.map(\.url) : outputs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
```

      and **delete** `CompressView.originalBytes(for:)` outright (Task 4 re-derived it while
      Phase 1's popover still needed the argument; Task 6 dropped that caller): its
      only caller was the `originalBytes:` argument of `HeavyCompressionPopover`, and Task 6's
      call-site update to `VersionsPopover(versions:onUse:onPreview:)` drops that argument, so the
      helper arrives at this task already dead. The aggregation it performed is now `RowVersions`'
      own `originalBytes`, which the popover reads off `versions` directly and this file reads in
      `status(for:)`'s `.done` arm above — nothing is lost by the deletion.

      Then make `outputNamePreview` honest for a recompress-only run:

```swift
        // A recompress replaces the row's existing file — naming a new one would be a lie.
        if model.armedCount > 0, model.pendingCount == 0 { return "replacing the current file" }
```

- [ ] Present the generalised popover and make the Quick Look freeze monotonic:

```swift
    @ViewBuilder
    private func heavyPopover(for job: ToolJob) -> some View {
        if let row = model.versions(for: job) {
            VersionsPopover(
                versions: row,
                onUse: { slot in
                    quickLookURL = nil
                    model.useVersion(slot, for: job)
                    heavyPopoverJobID = nil
                },
                onPreview: { url in
                    freezeQuickLookItems(row.cards.map(\.version.url))
                    quickLookURL = url
                })
        }
    }

    /// Frozen at preview-open and never allowed to SHRINK: a SwiftUI collection feeding
    /// `.quickLookPreview` that loses items while the panel is alive trips the
    /// `QLPreviewPanelController` KVO reload — the field crash. Two versions used to be the only
    /// case, so a plain overwrite was always same-size; with two OR three, previewing a 3-version
    /// row and then a 2-version one would shrink it.
    ///
    /// The padding repeats the CURRENT row's own last URL, never the previous set's tail. Padding
    /// with the old tail would leave the panel's arrow keys walking the user into a file belonging
    /// to a different row — or, after a slot replacement or "Clear finished", into a discarded
    /// path that no longer exists. A duplicate of a URL already in the set is inert by comparison:
    /// the arrows land back on a page the user is already looking at.
    private func freezeQuickLookItems(_ items: [URL]) {
        var next = items
        if let last = next.last {
            while next.count < frozenQuickLookItems.count { next.append(last) }
        }
        frozenQuickLookItems = next
    }
```

- [ ] Confirm — and leave a one-line comment where the answer is "unchanged, deliberately" — the
      remaining R17 aggregators: `savedBytes`, `savedDetail`, `savedSummary` (all three already
      route through `model.displayedSizes`, which Task 4 re-derived), `originalBytes(for:)`
      (**re-derived in Task 4** while Phase 1's popover still takes the `originalBytes:` argument,
      **deleted here** once Task 6 drops that caller — the aggregation it performed is satisfied at both its
      consumers by `RowVersions.originalBytes`: the popover reads it off `versions`, and this file
      reads it in `status(for:)`'s `.done` arm), `canRemove` (`.queued` only —
      an armed row is finished and stays non-removable, per D5's deferral), and the `.animation`
      values on the root view, which gain `value: model.armedCount` so arming animates like the
      other state changes. Also: the five disable/refuse sites (preset selector, + Add, Clear
      finished, `outputFolderRow`, the drop guard) already key on `model.isRunning`, which now
      spans both phases — unchanged, deliberately (R9). **Plus one model-side confirmation, because it is the last reader of a
      superseded URL:** `rerunForSwitch` must take its shipped and runner-up URLs from
      `versionStore.versions(for:)` and NOT from `job.resultURL`/`job.alternateURL` (fixed in Task
      4) — after a recompress the queue's record is the first run's, and it is nil outright on a
      no-gain row a recompress promoted, so a stale read would make "Use this" silently do nothing
      on exactly the rows this feature creates. Grep the branch for `resultURL` and `alternateURL`
      and account for every remaining hit. The complete list of legitimate survivors, produced by
      that grep rather than from memory:

      | Survivor | Why it stays |
      |---|---|
      | `ToolQueue.process`'s two writes (`jobs[index].resultURL`/`.alternateURL`) | R19 — the shared layer is not modified by any task |
      | `ToolQueue.JobResult`'s `alternateURL` property and its `init(_:outputURL:alternateURL:mrcReport:)` | R19 — the queue's own result type |
      | `ToolJob`'s `resultURL`/`alternateURL` declarations, their `init` initialisation to nil, and the type's doc comment naming `resultURL` | The queue's per-job record of the FIRST run. Still written, still read by OCR and by the fallbacks below; the store supersedes it for compress display only, it does not replace it |
      | The queue-phase `JobResult(outcome, outputURL: output, alternateURL: alternate, mrcReport:)` construction inside `compress()` | This is what PUTS the first run's URLs on the job — removing it would break the store's only queue-side input |
      | `ingestCompletedJobs`' own `guard let url = job.resultURL` / `let alternate = job.alternateURL` reads (added by Task 4) | The other half of that pair: the ingest reads back exactly what the construction above wrote, in the same emission. This is the ONE place the queue record is authoritative, because it is the moment before the store has a record at all |
      | `OCRView`'s `job.resultURL ?? job.url` open fallback | R19 — OCR has no version store |
      | `open`/`revealOutputs`' `?? job.resultURL` store-first fallbacks above | Deliberate: the store is asked first, the queue record is the fallback for a row the store has no entry for |
      | `ToolQueueTests.testResultURLIsAttributedToTheCorrectJob` and `ToolQueueTests.testAlternateURLFromJobResultLandsOnJob` | The queue's own contract, untouched by this feature |
      | The existing `CompressViewModelTests` FIRST-RUN reads — `resultURL` in `testSwitchTogglesInstantlyAndReversibly`, `testSwitchWithMissingRunnerUpRerunsJob` and `testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling`, and `alternateURL` in `testSwitchWithMissingRunnerUpRerunsJob`, `testSwitchFailingAfterRerunLeavesStateCanonical`, `testLaterBatchDoesNotRewriteAFinishedRowsPreset`, `testRemoveRowDiscardsRunnerUp` and `testClearFinishedDiscardsRunnerUps` | Each reads the URLs of a row that has only ever been through the QUEUE. A first-run row's queue record and its store record agree exactly — the ingest copies one into the other — so these reads are still correct and are left verbatim. Only a RECOMPRESSED row diverges, and no existing test recompresses |
      | `rerunForSwitch`'s comment "The STORE, never `job.resultURL`/`job.alternateURL`: the queue's record is the first…" (added by Task 4) | Names the symbols precisely in order to FORBID them — a deliberate survivor, not a stale read |
      | `testAQueuedJobNeverClaimsAnArmedRowsResultPath`'s `XCTAssertNotEqual(newRow.resultURL, armedRowOutput, …)` (added by Task 9) | Reads the queue record of a row that only went through the queue — same first-run-agreement reason as the row above |
- [ ] Pin the three lead rules this task encodes, in `CompressViewModelTests`. `lead(for:)` and
      `status(for:)` are private members of a `View` struct and are not reachable from the test
      bundle, so each test asserts the exact model-level PAIR the view maps one-to-one onto — the
      derivation, which is where every one of these three bugs actually lived. The rendering itself
      is covered by Task 5's `fileRowStateGallery` preview (which now carries an armed `.unchanged`
      row and a futile one) and by Task 13's driven self-test.

```swift
    // MARK: lead derivation (R2/R6/R10/R12)

    /// A no-gain row renders `.unchanged` (no shipped version ⇒ no size cluster) AND arms — the
    /// pair that made the armed pill invisible on exactly the rows R1 names as its user. Both
    /// halves must hold at once, which is what the view's `.unchanged` lead slot exists to draw.
    func testANoGainRowIsBothUnchangedAndArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        // Both halves, or the nil below would also pass for "there is no row at all" — the wrong
        // reason entirely, and one that would hide a broken no-gain ingest.
        XCTAssertNotNil(model.versions(for: job), "the no-gain attempt IS recorded")
        XCTAssertNil(model.versions(for: job)?.shipped,
                     "…and shipped nothing ⇒ the view renders this row `.unchanged`")
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "…and it is armed, so the `.unchanged` cluster must carry a lead")

        // The same row, futile: the neutral pill lives in that same slot.
        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced))
    }

    /// R10 at arming time: an armed row whose original is gone yields no prediction, which is the
    /// signal the view turns into the error lead instead of a confident pill.
    func testAnArmedRowWithAMissingOriginalOffersNoPrediction() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        try FileManager.default.removeItem(at: env.input)
        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize))
        XCTAssertTrue(model.isOriginalMissing(for: job))
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize))
    }
```

- [ ] Fix the one place the mockup contradicts the spec: in
      `.claude/specs/20260725-recompress-quality-evidence/recompress-ux-mockup.html`, the
      missing-original row on the edge-states screen drops the row's size cluster, but R10 keeps the
      shipped result and its versions intact. Give that row the same `was/now/pill/check` cluster
      its neighbours have, leaving the `⚠ The original file is no longer where it was` note leading
      it. (The spec is explicit: where prose and mockup disagree, the spec wins and the mockup gets
      fixed.)
- [ ] Build, then run the whole view-model suite:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -destination 'platform=macOS' -only-testing:ToolboxTests/CompressViewModelTests
```

- [ ] Commit: `feat(compress): show, arm and run the recompress flow in the compress view`

---

### Task 13: Gates and self-test evidence

**Model:** sonnet · **Track:** serial (Phase 3)

**Files**
- No source changes. Any failure here is a defect to report, never a reason to edit `GATES.md`.

**Steps**

- [ ] Regenerate the project (new files are glob-discovered, but the check is a gate):

```sh
xcodegen generate
```

- [ ] Run the build gate:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
```

- [ ] Run the full test gate in its gate form, and record the pass/fail counts:

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test -parallel-testing-enabled YES -parallel-testing-worker-count 8
```

- [ ] Run the packaged-app gate exactly as `.claude/GATES.md` states it (copy the command verbatim
      from the `packaged-app-compresses` gate — it is a single line with its own trap and mount
      parsing).
- [ ] Confirm the `no-personal-corpus-references` semantic gate over the branch diff: no absolute
      home paths, no account name, no private directory names, no description of any private
      corpus's contents. Every fixture in this plan is synthetic and generated in-process.
- [ ] Report the gate results verbatim. Then hand over for the human's own self-test: the app is
      launched and driven by the orchestrator, who checks the armed state, a real recompress, the
      three-card popover and the previous-version switch against the mockup. Do **not** attempt
      screenshots or browser automation from inside this task.
- [ ] Commit only if a gate run produced a change worth keeping (it should not):
      `chore(compress): record the recompress gate run` — otherwise no commit.

---

## Requirement coverage

| Req | Where |
|-----|-------|
| R1 arming rules | Task 7 (`recompressState`), Task 2 (`rowPreset`) |
| R2 armed row appearance | Task 5 (`FileRow.Lead`, `metaAccent`, `leadView` in all three finished clusters incl. `.unchanged`), Task 12 (`lead`/`metaAccent`, lead-derivation tests) |
| R3 reversibility | Task 7 (derived state; `testReselectingTheRowsPresetDisarmsIt`) |
| R4 banner and footer | Task 8 (`armedSummary`), Task 11 (`allFinished`, plus the three `armedSummary` arithmetic tests), Task 12 (headline/detail/button) |
| R5 mixed queued + armed | Task 10 (one run, counts), Task 12 (`actionTitle`) |
| R6 futile suppression | Task 7 (`futileAttempts`), Task 4 (first-run no-gain), Task 9 (recompress no-gain) |
| R7 instant switch | Task 7 (`.instantSwitch`), Task 11 (`useVersion(.previous,…)` end to end, and the vanished-previous message), Task 12 (`Switch instantly` link → `useVersion(.previous,…)`) |
| R8 direct-engine path | Task 9 (`recompress`, progress overlay, state flips at commit) |
| R9 batch semantics | Task 9 (`cancel()`: `runCancelled` + `recompressTask?.cancel()`, and the reclaim loop), Task 10 (phases, `runProgress`, the `runCancelled` guard before phase 2, terminal-row recording for `.done` AND `.failed`), Task 12 (running bar, disable rules) |
| R10 missing-original guard | Task 8 (`isOriginalMissing` gates `recompressPrediction`; `testPredictionIsWithheldWhenTheOriginalIsGone`), Task 9 (`testMissingOriginalReportsPerRowAndLeavesTheResultIntact`), Task 12 (error lead ahead of the armed pill; `testAnArmedRowWithAMissingOriginalOffersNoPrediction`) |
| R11 output path pinned + seeding | Task 1 (`reservationKey`), Task 9 (plans, seeding, two tests) |
| R12 commit protocol | Task 1 (`promote`'s three-step park-beside-shipped shape, four tests), Task 9 (`commit`, the `SwitchError` arm ahead of the generic catch, `recompressErrors` lifetime), Task 12 (error lead outranks the armed pill) |
| R13 ship what was asked | Task 9 (`commit` ships any outcome the engine returned; no extra gate) |
| R14 version store | Tasks 2, 4 (ingest), 9 (slot replacement discards) |
| R15 capsule + popover | Task 2 (`capsuleTitle`, `cards`), Task 6 (2/3 cards), Task 11 (capsule-on-plain-row), Task 12 (`.doneHeavy` on ≥2 versions, Quick Look freeze) |
| R16 estimate honesty | Task 3 (classification), Task 8 (calibration + three tests) |
| R17 aggregator sweep | Task 4 (model side, incl. `rerunForSwitch`'s URLs off the store), Task 11 (`allFinished`), Task 12 (view side, enumerated, incl. deleting the dead `originalBytes(for:)`, plus the tabulated `resultURL`/`alternateURL` grep survivors) |
| R18 cache lifecycle | Task 2 (`discardRow`/`retain`), Task 4 (funnelled removal), Task 11 (test) |
| R19 shared layer | Global constraint: `ToolQueue.swift` is not modified by any task |
| R20 tests | Distributed: Tasks 1, 2, 3, 7, 8, 9, 10, 11 each carry their own |
| D1 preview on select | Task 7 (arming changes nothing until the button) |
| D2 always from the original | Task 9 (`engine.compress(plan.url, …)` — the job's input) |
| D3 one previous version | Task 2 (single `previous` slot, replacement discards) |
| D4/R13 ship what was asked | Task 9 (`commit` has no "is it smaller than before" gate) |
| D5 batch-level only | Task 12 (`canRemove` unchanged; the lead slot leaves room for a leading checkbox later) |
| D6 session-only cache | Global constraint; Tasks 2 and 11 |

---

## Round 1 — 2026-07-25 — NO-SHIP (plan-reviewer, Opus)

Sixteen findings — one critical, five major, ten minor — all fixed in this round. The critical was
that Cancel could not stop the recompress phase: the outer `Task` was never held or cancelled,
`queue.cancel()` lets `queue.run` return normally so phase 2 began unconditionally, and
`recompressTask` is nil for the whole of phase 1, making an early Cancel a no-op; the plan now
carries a run-scoped `runCancelled` flag cleared at run start, a guard at the top of
`runRecompressPhase`, a held `runTask`, a new phase-1 cancellation test, and a corrected premise for
`testCancellingARecompressKeepsThePreviousResult` (which would otherwise have passed without ever
entering the engine). The majors were: no-gain rows render `FileRow.Status.unchanged`, which drew no
lead at all, so the armed and futile pills were invisible on exactly the rows R1/R6 name (Task 5 now
draws `leadView` in the `.unchanged` cluster, per the approved mockup, with preview rows and Task 12
assertions); `lead(for:)`'s `state == .none` guard suppressed R12's failure message on every row that
re-armed after failing (error now outranks the armed pill, with `recompressErrors` given an explicit
lifetime — cleared only by a preset change or the next run); `promote` parked the user's delivered
file inside the swept-at-launch cache before promoting it, losing it to any crash in that window and
degrading to copy+delete across volumes (now mirrors `switchVersions`' three-step
park-beside-shipped shape, with the best-effort third step's discard-not-strand semantics documented
and tested); `recompress`'s generic catch swallowed `SwitchError.shippedStranded` into "kept your X
version" when the shipped file is emphatically *not* kept (a typed arm now precedes it and drops the
row's version record via `reportSwitchFailure`); `rerunForSwitch` still read `job.resultURL` /
`job.alternateURL`, both superseded by every recompress commit and nil outright on a promoted no-gain
row, so "Use this" would silently do nothing (now derived from the store, with a grep confirmation in
Task 12); and R10's arming-time missing-input check was unimplemented, letting an armed row with a
deleted original show a confident pill (`isOriginalMissing` now gates `recompressPrediction`, with
tests in Tasks 8 and 12). The minors: `runCompleted` was declared twice (Task 10's duplicate
removed, pointer left to Task 9); Task 4's rename mapping was incomplete and miscounted the safety
net (complete member table, the optional-URL decision recorded as a single unwrap at the top of the
popover's `body`, count corrected from twelve to ten with all ten named); `discardRunnerUp`'s
`switchFailures` clear said "existing" where no such line exists (now "add", flagged as a defect fix
riding the refactor); `compress()`'s tail was written with ellipses (now printed once, whole, with
`runReservations` and `runComposition` integrated and `RunComposition` moved to Task 10 where the run
bookkeeping lives); failed queue rows never entered `runCompleted`, stalling the run bar short of 1
(recorded from the `queue.$jobs` sink for `.done` **and** `.failed`, over a `runQueuedIDs` subset
rather than `runIDs` — an armed row is `.done` throughout, so a `runIDs` sweep would have counted
every armed row as finished at run start and opened a mixed run's bar at 50%); Global Constraints listed four gates where `GATES.md` declares
seven (all seven now tabulated with unaffected/covered/run stated per gate); the File Structure table
credited the mockup correction to Task 11 instead of Task 12; `freezeQuickLookItems` padded with the
previous row's stale tail, letting the panel's arrows reach a foreign or deleted file (now pads by
repeating the current row's own last URL, with the reason in the comment); and Task 8's third
prediction test claimed the scaled branch when a born-digital row at Maximum quality takes the raw
branch (comment corrected, including the honest reason the guard fires). No file set changed: every
presentation fix stayed in `Components.swift` (Track P) and every behavioural fix in
`CompressViewModel.swift` + its tests (Track E), so Track P/E disjointness holds exactly as stated.

**Lesson-candidates** (the reviewer's, one line each):

1. A display affordance added to *some* status branches but not the branch the requirement names — enumerate every branch of the status enum against the requirement's own list of row kinds.
2. An execution path left on the old model when the sweep enumerated only display paths — sweeps must cover *writers* and re-run paths, not just readers.
3. A commit primitive that copies a sibling's failure shapes while dropping the sibling's crash-window guarantee — "same semantics as X, for the same reason" is a claim to check against X's *comments*, not just its control flow.
4. A phase serialised for concurrency but not for cancellation — "B runs after A" satisfies a concurrency bound and silently creates a cancellation hole: cancelling A merely makes A return, which *starts* B.
5. A model-level test greening a display the user never sees — where a requirement says "never fails silently", the assertion belongs at the view-derivation function.

---

## Round 2 — 2026-07-25 — NO-SHIP (plan-reviewer, Opus, incremental)

Eleven findings — one critical, two major, eight minor — all fixed in this round; 13 of round 1's 16
findings were re-verified as genuinely resolved by the diff. The critical re-opened the cancel chain
round 1 had closed at the wrong end: `recompress` went engine call → `commit` with no cancellation
check between, and because the stub's `Gate.wait()` is non-throwing, `model.cancel(); await
gate.open()` let the stub RETURN and the commit promote — `testCancellingARecompressKeepsThePreviousResult`
would have failed, and in production a cancel landing after `CompressEngine`'s final
`Task.checkCancellation()` (which precedes its rename-and-return) would have overwritten the
delivered file; a `try Task.checkCancellation()` now sits immediately before `commit`, routing into
the existing `catch is CancellationError` arm. The majors: Task 9's "run the suite; all green" was
unsatisfiable because both new cancel tests live in Task 9 while `runCancelled = true` and
`recompressTask?.cancel()` were only written in Task 10 (Task 9 now owns its own `cancel()` step with
those two lines, and Task 10 layers only `runTask?.cancel()` and the reservation change on top, each
task saying so explicitly); and Task 8's `testPredictionIsWithheldWhenTheOriginalIsGone` had an
impossible positive control — a `.bornDigital` `HeavyEnv` takes the raw-estimate branch, whose figure
derives from the multi-megabyte `imagePDF` fixture, so the prediction was already nil before the
deletion (now `.scanColour`, where `targetWantsMRC == shippedWasMRC` at `.smallestSize` so the
calibration branch runs and the prediction tracks the shipped 1.2 kB, with the mechanism pinned in
the comment). The minors: `runCancelled`'s doc comment claimed a third mechanism that cannot fire
(`runTask.cancel()` reaches nothing in the run body, which reads `Task.isCancelled` nowhere) and
contradicted its own "`Task.init` does NOT inherit cancellation" two lines above (parenthetical and
"none is redundant" both gone; `runTask?.cancel()` kept with an honest no-current-reader note in both
places); Task 4's `normalTitle` mapping keyed off `runnerUp.variant`, which `swapShipped` moves, so
the button would lie after a switch (now the same positional selector shape as `heavyURL`/`normalURL`),
and the popover's new body comment cited the `heavyVersions(for:)` that this very task deletes (now
`versions(for:)` plus Task 12's `row.count > 1` → `.doneHeavy` condition); `discardRunnerUp`'s new
`switchFailures` line carried a false justification — `ToolJob.init` mints a fresh `UUID` per `add`
and `pruneStaleEstimateState` already filters `switchFailures` on every sink emission (line kept, real
reason stated, "defect fix" framing and the commit-body instruction dropped); Task 8 had inserted
`isOriginalMissing` between `recompressPrediction`'s doc comment and its declaration, silently
re-attributing the calibration paragraphs (block split, each comment on its own member); the Track
plan's "Round 1's fixes changed no file set" was false and Phase 3's exact-file-set column omitted
`CompressViewModel.swift` and `CompressViewModelTests.swift` (row completed, claim narrowed to "no
FORK file set changed"); two test doc comments naming `heavyVersions(for:)` would have survived Task
4's call-sites-only rename (both added to the mapping step); and Task 5 gave `.done` and `.unchanged`
a lead without the `.fixedSize()` that the `.doneHeavy` arm documents as necessary against R8's
single-line height, which neither previews nor the build can catch (both arms now carry it with the
same one-line reason); finally the File Structure table credited `reservePreviousURL` to
`RunnerUpStore.swift` when it is declared on `VersionStore` and forwards to
`cache.reserveURL(for:suffix:reserving:)` (rows corrected, with `RunnerUpStore`'s row naming the
`reserveURL` suffix widening and `promote`).

**Lesson-candidates** (the reviewer's, one line each):

1. A numeric premise about a generated fixture is a measurement, not a sentence: a test's positive control must be checked against the fixture's real magnitude before it is written.
2. Sharpening a test's premise without landing the mechanism it now exercises converts a vacuous pass into a failing gate — when a fix changes a wait condition, re-derive the whole test's outcome, not just the window it observes.
3. A fix that spans a task boundary must land its mechanism in the earlier task: a test added in task N whose enabling line is written in task N+1 makes N's own green gate unreachable.
4. Inserting a member is a diff on its neighbours' documentation too — a new declaration placed between an existing doc comment and its owner silently re-attributes the comment.
5. A mapping from an intrinsic field to a positional one must be checked against the operation that swaps positions: equivalence at rest is not equivalence after the swap.
6. A justification invented while fixing a minor is a claim like any other — it needs the id-lifetime and prune checks before it is written into a commit body.

---

## Round 3 — 2026-07-25 — NO-SHIP (plan-reviewer, Opus, incremental)

All eleven of round 2's findings were verified as genuinely resolved by the diff. One new major:
`testPredictionScalesByTheObservedRatioWhenThePathRepeats` carried the same impossible premise round
2's fix corrected in its neighbour — `HeavyEnv` always ships `.compressedHeavy` (`shippedWasMRC` is
always true) while `.bornDigital` gives `targetWantsMRC == false`, so no calibration ever applied and
the raw multi-megabyte estimate could never beat the 9000-byte original, making the `XCTUnwrap`
unsatisfiable (now `.scanColour` at `.smallestSize`, the only HeavyEnv-reachable pair giving
`targetWantsMRC == shippedWasMRC == true` with a non-degenerate ratio, without touching R16 or
`recompressPrediction` itself, both already correct). Three minors: the `catch is CancellationError`
arm's comment still described only the pre-checkpoint throwing path as if it were the only one,
when the post-checkpoint path Round 2 added now also lands there with a real result on disk at
`plan.temp` (and `plan.runnerUp`) that the same two lines discard (comment now names both paths);
`runTask` was dead machinery by the plan's own admission ("no current reader") — deleted from its
declaration, its `Task { … }` assignment, its `= nil` clear, and its `cancel()` call, with the
surrounding prose in Tasks 9 and 10 corrected to match; and Task 4's Files list omitted the two files
its own steps modify (`HeavyCompressionPopover.swift` and the `CompressView.swift` accessor rename),
now added there and to the Phase 1 track-plan row.

**Lesson-candidates** (the reviewer's, one line each):

1. Fixing a premise defect in one test of a block obliges re-deriving every sibling in that block against the same implementation.
2. Rewriting a doc comment to be honest is a proof, not a patch: the moment a comment reads "no current reader", the member is dead and the follow-through is deletion, not annotation.
3. A test's numeric headroom that rests on an unmeasured generated fixture is an unverified premise even when the test passes — a repeat-offender class now, belongs in review-lessons.md.
4. Inserting a cancellation checkpoint routes a new path into an existing catch arm — the arm's comment is part of the diff's blast radius, not just its control flow.
## Round 4 — 2026-07-25 — SHIP pending certify (plan-reviewer, Opus, incremental)
All four round-3 findings verified resolved — the corrected prediction test re-derived end to end (its headroom is now an algebraic bound over the whole input domain, independent of the fixture's size), the runTask deletion proven compile-safe against the shipping code, Task 4's file list confirmed load-bearing. Three new minors, all comment/table accuracy, fixed this round: the cancellation-arm comment now states the alternate conditionally; the R9 coverage row credits cancel() to Task 9 and drops the deleted third mechanism; the "only reachable pair" claim is scoped to this row's shipped preset. Lesson-candidates: an algebraic bound over the input domain beats a fixture measurement as a test premise; deleting a member is a diff on every index that describes it; a comment fixed to cover a second path must state each path's artefacts conditionally; "the only reachable X" is a universal quantifier and carries its proof burden.

## Round 5 — 2026-07-25 — NO-SHIP (plan-reviewer, Opus, full certify)

Round 4's three minors were verified as landed. The full certify then found what four incremental
rounds could not: one MAJOR — this feature's own new `compress()` semantics break an EXISTING test.
`testLaterBatchDoesNotRewriteAFinishedRowsPreset` runs its second batch at a preset the finished row
was not compressed at, which before this feature left that row inert and after it ARMS the row, so
phase 2 recompresses it, `setSlot` discards the runner-up the test then tries to delete, and the
switch takes the instant branch instead of the re-run the test waits for — making Task 10's "all
green" and Task 13's mandated test gate unreachable while Task 4 forbids rewriting the assertion.
Resolved intent-preserving: Task 10 now runs that second batch at the row's own preset and moves the
preset change to after it (row armed, never run, runner-up intact, re-run still exercised, and the
assertion stronger as a discriminator, verbatim), with Task 4's binding constraint clarified as
binding the assertion, and a suite-wide audit step tabulating all seventeen tests that call
`compress()` against the rule that only a second `compress()` over a differently-presetted finished
row is affected. Nine minors, all fixed this round: the plans loop now reuses the queued pass's
`outputs[job.id]` instead of allocating a second time from the shared reservation ledger (which
would have handed a promoted no-gain row `<name>-compressed-1.pdf`); Task 4's doc-comment step grew
from two entries to a six-row table, with the two `normalTitle` citations reworded to Track P's
surviving `VersionsPopover.label(_:slot:)` vocabulary so no later track reaches back into Track E's
file; `pruneStaleEstimateState` now filters `pendingPresets` (whose entry a `.failed` job never
consumes) and `recompressErrors`; Task 12 DELETES the dead `CompressView.originalBytes(for:)` rather
than re-deriving it, with the R17 sweep line saying so; the `resultURL`/`alternateURL` survivor list
is now a grep-produced table naming the queue-phase `JobResult` construction, `ToolJob`'s own
declarations and init, and each existing first-run test read; `armedSummary`'s arithmetic gains
three tests in Task 11, one per branch, each on a pair Task 8 already proved reachable;
`useVersion(.previous,…)` gains an end-to-end test asserting the on-disk swap and a second for the
vanished-previous message; the recompress-error lifetime test now asserts the next-run half its own
name promises; and Task 9 records a one-line disposition for its per-tick `Task { @MainActor in … }`
against `ToolQueue.process`'s stricter FIFO comment, keeping the mechanism.

**Lesson-candidates** (the reviewer's, one line each):

1. A behaviour change to a shared entry point is a diff on every existing test that calls it.
2. Two allocation loops over the same job set will collide through the reservation ledger they share — reuse the first pass's allocation.
3. An enumeration written as a closed list is a claim that must be produced by grep, not by memory — and omitted items in another track's file are also a track-independence defect.
4. Deleting a call site makes its callee dead; the sweep that re-derives the callee should have deleted it.
5. A member carrying arithmetic a prior gate flagged as subtle must arrive with a test — the untestable consumer is the argument for the model-level test, not against it.
6. Replacing a piece of bookkeeping means inheriting its lifecycle guards.
## Round 6 — 2026-07-25 — SHIP pending certify (plan-reviewer, Opus, incremental)
The round-5 major and all nine minors verified resolved against the repo (audit table's 18-call count re-grepped; every survivor-table attribution checked line by line; all three armedSummary branch premises re-derived; the previous-swap test traced through swapShipped and commit). Three new minors, fixed this round: two rows added to the survivor table for hits the fix's own new code introduces (rerunForSwitch's deliberate "never these" comment; the new queued-vs-armed path test), the originalBytes(for:) traceability claim now states re-derived-in-Task-4-then-deleted-in-Task-12 in both places, and the "stronger discriminator" comparative names both states. Lesson-candidates: a "complete list produced by grep" must be re-grepped against the document's own new code; when a later task deletes what an earlier task re-derived, say so in both places; a comparative claim is an assertion about two states — name both or use the absolute form; a semantics change to one shared read prompts a grep for every other shared read the change-set redefines (allFinished checked — clean).

## Round 7 — 2026-07-25 — NO-SHIP (plan-reviewer, Opus, full certify)

The full certify found three MAJORS that four incremental rounds could not see, all of them
consequences of a change being checked only where the round's diff pointed. Task 4's
`HeavyVersions` → `RowVersions` mapping table was scoped to the test file and to the popover, and
missed `CompressView.status(for:)`'s one inline `versions.displayedBytes` read in the
`.compressedHeavy` arm — a member `RowVersions` does not have, so Task 4's own build step could not
pass; the arm now maps to `versions.shipped?.bytes ?? after` as an interim behaviour-preserving
form, superseded wholesale by Task 12's store-driven `.done` arm. The `Gate` test double shared by
every gated test is a single-continuation latch, and Task 10's new
`testRunProgressIsScopedToTheRunsOwnRows` is the first test in the suite to suspend TWO engine
calls behind it at once (phase 2 launches up to `performanceCoreCount` children), so the second
waiter would overwrite and orphan the first and the test would hang rather than fail, making the
mandated `tests` gate unreachable; Task 10 now opens with a step making the latch multi-waiter,
which touches a helper rather than an assertion and so does not collide with Task 4's binding
constraint. And `testAQueuedJobNeverClaimsAnArmedRowsResultPath` — the plan's only regression test
for R11's reservation seeding — passed identically with the seeding deleted, because in its
scenario the unfiltered queued allocation loop re-reserves the armed row's name anyway; it is
rewritten around a decoy file planted at `outputFolder/image-compressed.pdf` before the first
batch, so the armed row ships at `image-compressed-1.pdf`, and with both the decoy and the row's
file removed the second batch hands the new job exactly that path unless the seeding stops it.
Four minors, all fixed this round: `commit()`'s guard-let-row and `.ocrAdded`/`.alreadySearchable`
returns now clean up `plan.temp` and the runner-up reservation as the `.noGain` arm already did,
with a note that both are unreachable by construction and cleaned anyway; `SuccessBanner.Tone`'s
accessor is renamed `colour` → `color` to match its file's siblings (`StatPill.Tone.color`,
`Theme.Shadow.color`), the doc-comment prose staying British, and the global constraint that
produced the mistake is restated as the nearest-sibling rule; the coverage table's R9 row credited
Task 12 with "disable rules" it had no step for, so Task 12's R17 confirm bullet now names the five
disable/refuse sites that key on `model.isRunning` and records them as deliberately unchanged; and
the `preset` observer no longer republishes twice, `recompressErrors = [:]` moving above
`reestimatePendingJobs()` (whose whole body is `publishJobs()`) and the trailing `publishJobs()`
going away.

**Lesson-candidates** (the reviewer's, one line each):

1. A member-mapping table scoped to one file is not a sweep: enumerate the deleted type's readers per consumer file and grep each.
2. A shared test double is part of the concurrency contract — the first test to exercise a code path at width > 1 must re-derive the double's own arity.
3. A regression test for a reservation must be built on a state where the reservation is the only thing preventing the collision.
4. A cleanup performed on one arm of a switch and omitted on its siblings is a finding even when the siblings are unreachable.
5. Spelling convention for code identifiers is decided by the nearest sibling in the same file, not by the prose rule.
6. A coverage table entry naming a task is a claim that the task has a step for it — grep the task before writing the row.
## Round 8 — 2026-07-25 — SHIP pending certify (plan-reviewer, Opus, incremental)
All three round-7 majors and four minors verified resolved with receipts (the completeness sweep re-run including the defining file; the seeding test's negative control walked to the assertion; every gated test re-counted against the multi-waiter Gate's placement). Fixer's two scope additions accepted after first-hand checks. No new findings at any severity. Lesson-candidates: a per-consumer-file sweep must include the file that defines the type; copy a "these N controls" enumeration from the spec's own list; walk a negative control to the assertion, not just the allocation; a replaced shared double must land at the first task needing the new arity, with every earlier gated test re-counted.
