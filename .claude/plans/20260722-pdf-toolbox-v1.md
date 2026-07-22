# PDF Toolbox v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS app, **PDF Toolbox**, with two working tools — **Compress** (Ghostscript-core, Rung 1) and **OCR** (Apple Vision) — in an extensible SwiftUI shell, packaged as an ad-hoc-signed DMG with GitHub Actions CI.

**Architecture:** Depth-first. A thin end-to-end vertical slice (shell → shared PDF spine → bundled Ghostscript → Rung-1 compress → validated output) is built and proven FIRST (the M1 gate). Everything after — OCR, batch queue, presets, estimate, UI polish — is incremental breadth on a known-good base. No big-bang integration.

**Tech Stack:** SwiftUI, Swift 5.9+, macOS 14+ (Apple Silicon), XcodeGen + xcodebuild, bundled Ghostscript (arm64, built from source per the spike recipe), Apple Vision (`VNRecognizeTextRequest`), PDFKit, `sandbox-exec` (seatbelt) for GS containment. Licence AGPL-3.0.

**Spec:** `.claude/specs/20260722-pdf-toolbox-v1.md` (approved 2026-07-22). This plan is subordinate to the spec; on any conflict the spec wins.

## Global Constraints

- **Platform:** macOS 14.0 minimum deployment target; Apple Silicon (arm64). Built with Xcode 26.6 / macOS 26 SDK.
- **Licence:** AGPL-3.0. Every source file carries a short AGPL header. Repo private during dev, public at release.
- **Build:** XcodeGen generates `PDFToolbox.xcodeproj` from `project.yml`; `xcodebuild` is the build driver. No `.xcodeproj` committed (generated). CI regenerates it.
- **Signing:** ad-hoc only (`codesign -s -`) — no Developer ID cert available. Hardened runtime enabled. Notarisation deferred (needs user's Apple Developer credentials); CI notarise step guarded on secrets.
- **Naming/copy:** Product name "PDF Toolbox". Output files: `<name>-compressed.pdf` / `<name>-ocr.pdf` written next to the original (batch: optional output-folder picker). British English in all prose/comments/commits; code identifiers follow platform/library spelling.
- **Privacy (HARD):** Never commit anything about the user's personal test PDFs at `<private local corpus>` — no path, names, sizes-tied-to-names, contents, or subject matter. Committed fixtures are synthetic only. Local quality validation on the real corpus reports anonymised aggregates only.
- **GS containment:** every Ghostscript invocation runs under `sandbox-exec` with a profile denying network and scoping filesystem to the specific input + output paths, plus `-dSAFER` and resource caps. Never a bare `Process`.
- **Output safety:** compress/OCR write to a temp file then atomically rename; never overwrite the input; compress never emits a file larger than the input (fall back to copying the original if gs output is bigger); every output re-validated (page count matches + N sample pages render) before it is called done.
- **DoD floor:** v1 is "done" with **Rung 1 Compress + OCR** working, tested, DMG'd. Rung 2 (jbig2enc/CCITT) and Rung 3 (MRC) are explicitly deferred stretch — attempted only if the core lands with hours to spare, never at the cost of polish or stability.

---

## File Structure

```
toolbox/
  project.yml                          XcodeGen spec (app + tests targets)
  LICENSE                              AGPL-3.0 text
  Sources/PDFToolbox/
    App/
      PDFToolboxApp.swift              @main, WindowGroup
      RootView.swift                   NavigationSplitView shell
      SidebarView.swift                tool list (Compress, OCR, + Soon)
      Tool.swift                       enum of tools + metadata
    DesignSystem/
      Theme.swift                      colour/type/spacing tokens from DESIGN.md
      Components.swift                 PrimaryButton, Card, DropZone, StatPill, etc.
    Models/
      ToolJob.swift                    a queued file + its state
      CompressPreset.swift             preset enum → gs params
      PDFContentType.swift             .bornDigital/.mixed/.scan/.bilevel classification
    Services/
      PDFService.swift                 load, pageCount, classify, render-sample
      GhostscriptRunner.swift          locate bundled gs, run sandboxed
      SeatbeltProfile.swift            build the sandbox-exec profile
      PDFWriter.swift                  incremental-update append (OCR text layer)
      OutputValidator.swift            page-count + render-sample validation
    Compress/
      CompressEngine.swift             route + run Rung-1 gs compress
      CompressEstimator.swift          time-boxed per-file size estimate
      CompressView.swift               UI
      CompressViewModel.swift          state, queue binding
    OCR/
      VisionOCR.swift                  VNRecognizeTextRequest per page
      OCREngine.swift                  detect image-only pages, orchestrate
      OCRView.swift                    UI
      OCRViewModel.swift               state
    Shared/
      ToolQueue.swift                  batch queue (ObservableObject)
      FileNaming.swift                 output path derivation
      Log.swift                        os.Logger wrapper
  Resources/
    ghostscript/                       bundled gs binary + Resource tree (from spike)
  Tests/PDFToolboxTests/
    Fixtures.swift                     synthetic PDF generators (born-digital, image, bilevel)
    CompressEngineTests.swift
    PDFServiceTests.swift
    OutputValidatorTests.swift
    PDFWriterTests.swift
    OCREngineTests.swift
    FileNamingTests.swift
  scripts/
    build-ghostscript.sh              reproducible gs build (from spike; used by CI)
    package-dmg.sh                    build .app → ad-hoc sign → DMG
  .github/workflows/
    build.yml                          CI: build gs, build app, test, package DMG, (guarded) notarise+release
```

---

# PHASE 0 — Foundation spine (SERIAL — the M1 gate). Track: `spine`. Model: Opus.

This whole phase is one dependency chain, built serially by the orchestrator's loop. It ends at the M1 gate: **app launches, compresses a synthetic PDF, saves a validated `-compressed.pdf`.** Nothing in Phase 1 starts until M1 is green and committed.

### Task 0.1: XcodeGen project + launching SwiftUI shell
**Track:** spine · **Model:** Opus · **Depends:** none

**Files:**
- Create: `project.yml`, `LICENSE`, `Sources/PDFToolbox/App/PDFToolboxApp.swift`, `RootView.swift`, `SidebarView.swift`, `Tool.swift`
- Create: `Sources/PDFToolbox/DesignSystem/Theme.swift` (minimal token stub — full styling in Phase 1 Track D)

**Interfaces:**
- Produces: `enum Tool: String, CaseIterable, Identifiable { case compress, ocr }` with `title`, `systemImage`, `isAvailable` (Compress/OCR available; Merge/Split as `.soon` cases rendered disabled per spec §7 deviation list — a 4-entry sidebar: Compress, OCR, Merge (Soon), Split (Soon)). `RootView` owns `@State selectedTool: Tool`.

- [ ] **Step 1:** Write `project.yml` — one app target `PDFToolbox` (bundleId `com.pdftoolbox.app`, deployment 14.0, arm64, `INFOPLIST_KEY_LSMinimumSystemVersion`, hardened runtime settings), one unit-test target `PDFToolboxTests`. Include `Resources/` as a folder reference so `Resources/ghostscript/` bundles.
- [ ] **Step 2:** Write `PDFToolboxApp.swift` (`@main`, `WindowGroup { RootView() }`, min window size 900×620), `RootView.swift` (`NavigationSplitView` sidebar + detail placeholder per tool), `SidebarView.swift`, `Tool.swift`.
- [ ] **Step 3:** Add AGPL `LICENSE`, per-file AGPL headers.
- [ ] **Step 4:** `xcodegen generate` then `xcodebuild -project PDFToolbox.xcodeproj -scheme PDFToolbox -configuration Debug build`. Expected: BUILD SUCCEEDED.
- [ ] **Step 5:** Launch the built `.app` (smoke): `open` it, confirm window + sidebar appears (verify via screenshot / accessibility dump, then kill). Commit `feat: scaffold PDFToolbox app shell (XcodeGen + SwiftUI NavigationSplitView)`.

### Task 0.2: Bundle Ghostscript + GhostscriptRunner
**Track:** spine · **Model:** Opus · **Depends:** 0.1, gs-build-spike

**Files:**
- Create: `scripts/build-ghostscript.sh` (verbatim from the spike's proven recipe), `Resources/ghostscript/` (built artifacts), `Sources/PDFToolbox/Services/GhostscriptRunner.swift`, `SeatbeltProfile.swift`
- Test: `Tests/PDFToolboxTests/GhostscriptRunnerTests.swift`

**Interfaces:**
- Produces: `struct GhostscriptRunner { init() throws; func run(arguments: [String], inputURL: URL, outputURL: URL) throws -> ProcessResult }` — locates the bundled `gs` at `Bundle.main.url(forResource:...)`, sets `GS_LIB`/`-I` to the bundled Resource tree, wraps the call in `sandbox-exec -f <profile>` (network denied, FS scoped to input+output+bundle), applies `-dSAFER` + resource caps. `struct ProcessResult { let exitCode: Int32; let stdout: String; let stderr: String }`.
- Produces: `enum SeatbeltProfile { static func profile(readPaths: [URL], writePaths: [URL], bundlePath: URL) -> String }`.

- [ ] **Step 1:** Commit `scripts/build-ghostscript.sh` and run it → populate `Resources/ghostscript/` (binary + dylibs + Resource tree, install-names rewritten to `@executable_path`/`@rpath` per spike). Verify `Resources/ghostscript/bin/gs --version` runs from a scrubbed PATH.
- [ ] **Step 2:** Write `SeatbeltProfile.swift` — generate a seatbelt profile string: `(version 1)(deny default)(allow process-exec* ...)(deny network*)(allow file-read* (subpath "<bundle>") (literal "<input>"))(allow file-write* (literal "<output>") (subpath "<tmp>"))`. Unit-test the generated string contains the deny-network + scoped paths.
- [ ] **Step 3:** Write `GhostscriptRunner.swift`. Write failing test: run `gs --version` through the runner, assert exit 0 and version string present.
- [ ] **Step 4:** Run test → PASS. Also assert a network attempt is blocked (best-effort: profile string check + a gs invocation that would need no network succeeds).
- [ ] **Step 5:** Commit `feat: bundle Ghostscript arm64 and add sandboxed GhostscriptRunner`.

### Task 0.3: Shared PDF spine — models + PDFService
**Track:** spine · **Model:** Opus · **Depends:** 0.1

**Files:**
- Create: `Models/ToolJob.swift`, `Models/CompressPreset.swift`, `Models/PDFContentType.swift`, `Services/PDFService.swift`, `Shared/FileNaming.swift`, `Shared/Log.swift`
- Test: `Tests/PDFToolboxTests/PDFServiceTests.swift`, `FileNamingTests.swift`, `Fixtures.swift`

**Interfaces:**
- Produces: `enum CompressPreset: String, CaseIterable { case maximumQuality, balanced, smallestSize }` each mapping to a `gsSettings` param set (dPDFSETTINGS + explicit image-downsample DPI/quality overrides — values from spec §5).
- Produces: `enum PDFContentType { case bornDigital, mixed, scan, bilevel }`.
- Produces: `struct PDFService { func pageCount(_ url: URL) throws -> Int; func classify(_ url: URL) throws -> PDFContentType; func renderSample(_ url: URL, pages: Int) throws -> [CGImage] }` — classify by sampling pages: text-layer presence + image coverage ratio + colour depth (born-digital = has text, low raster; mixed = text + images; scan = full-page images, no text; bilevel = scan that is ~1-bit).
- Produces: `enum FileNaming { static func output(for input: URL, suffix: String, folder: URL?) -> URL }`.
- Produces: `struct ToolJob: Identifiable { let id; let url: URL; var state: JobState; var resultURL: URL?; var estimate: SizeEstimate? }`, `enum JobState { case queued, analysing, running(Double), done(bytesBefore:Int, bytesAfter:Int), failed(String) }`.

- [ ] **Step 1:** Write `Fixtures.swift` — generate synthetic PDFs at test time via `PDFDocument`/Core Graphics: `bornDigitalPDF()` (text), `imagePDF()` (embeds a generated photo-like CGImage), `bilevelPDF()` (1-bit scan-like). Never read from disk.
- [ ] **Step 2:** Write failing `PDFServiceTests`: pageCount of a 3-page fixture == 3; classify(bornDigital) == .bornDigital; classify(image) == .scan.
- [ ] **Step 3:** Implement `PDFService`, `PDFContentType`, `CompressPreset`, `FileNaming`, `ToolJob`, `Log`. Run tests → PASS.
- [ ] **Step 4:** Write + pass `FileNamingTests` (suffix, collision `-compressed-1.pdf`, output-folder override).
- [ ] **Step 5:** Commit `feat: add PDF content classification, models, and file-naming`.

### Task 0.4: Rung-1 CompressEngine + OutputValidator + end-to-end UI wire
**Track:** spine · **Model:** Opus · **Depends:** 0.2, 0.3

**Files:**
- Create: `Services/OutputValidator.swift`, `Compress/CompressEngine.swift`, `Compress/CompressView.swift`, `Compress/CompressViewModel.swift`
- Test: `Tests/PDFToolboxTests/CompressEngineTests.swift`, `OutputValidatorTests.swift`

**Interfaces:**
- Produces: `struct OutputValidator { func validate(input: URL, output: URL, samplePages: Int) throws -> Bool }` — page counts equal AND N sample pages render non-blank (compare against input renders for gross corruption).
- Produces: `struct CompressEngine { init(runner: GhostscriptRunner); func compress(_ input: URL, preset: CompressPreset, to output: URL, progress: (Double)->Void) async throws -> CompressResult }` — routes `.bornDigital`/`.mixed`/`.scan`/`.bilevel` all to Rung-1 gs for v1 (Rungs 2/3 deferred — router has the seam but one implementation now); temp-file + atomic rename; never-bigger guard (if gs output ≥ input, copy input to output and flag `.noGain`); calls `OutputValidator`. `struct CompressResult { let bytesBefore, bytesAfter: Int; let validated: Bool; let noGain: Bool }`.

- [ ] **Step 1:** Write failing `OutputValidatorTests` (equal-page-count pass; mismatched-page-count fail; blank-output fail).
- [ ] **Step 2:** Implement `OutputValidator`; tests PASS.
- [ ] **Step 3:** Write failing `CompressEngineTests`: compress `imagePDF()` at `.balanced` → output smaller than input, validated true, page count preserved. Test never-bigger guard with `bornDigitalPDF()` (tiny; likely no gain → `.noGain`, output == input bytes).
- [ ] **Step 4:** Implement `CompressEngine`; tests PASS.
- [ ] **Step 5:** Wire `CompressView` + `CompressViewModel`: a drop zone / file picker for ONE file, a preset control, a Compress button, a result row (before/after size). No batch yet. Build, launch, manually compress a synthetic PDF through the GUI, confirm `-compressed.pdf` appears and validates.
- [ ] **Step 6:** **M1 GATE.** Commit `feat: Rung-1 Ghostscript compress engine wired end-to-end (M1)`. Update ledger: M1 green.

---

# PHASE 1 — Breadth (parallelizable after M1). Three tracks, file-disjoint.

Dispatched as concurrent background subagents, one per worktree, ONLY after M1 is committed. Each track's files are disjoint (see below). The orchestrator owns cross-track seams (shared model additions land in Phase 0; tracks consume, don't mutate, each other's files).

### Track B — OCR tool. Model: Opus (Vision + PDF incremental append is subtle). Files: `OCR/*`, `Services/PDFWriter.swift`, `Tests/…/PDFWriterTests.swift`, `OCREngineTests.swift`.

### Task B.1: PDFWriter — incremental-update invisible text layer
**Depends:** 0.3

**Interfaces:**
- Produces: `struct PDFWriter { func appendTextLayer(to input: URL, output: URL, pageTexts: [Int: [PositionedText]]) throws }` where `struct PositionedText { let text: String; let rect: CGRect /* PDF user space */; }`. Appends an invisible text-render-mode-3 layer via PDF incremental update so the original image bytes are untouched (append-only; original object table preserved). Validates: output opens, page count == input, original page objects byte-identical.
- Produces: coordinate contract — Vision normalised (origin bottom-left, 0–1) → PDF user space accounting for page `mediaBox` + rotation.

- [ ] Step 1: Failing `PDFWriterTests` — append a known string to a 1-page image PDF; reopen; assert extractable text present AND original image XObject bytes unchanged (compare object stream).
- [ ] Step 2: Implement incremental-update append (write original bytes verbatim, append new objects + xref delta + trailer with `/Prev`). Text render mode 3 (invisible), font Helvetica, sized to bbox.
- [ ] Step 3: Tests PASS. Commit `feat: PDFWriter incremental-update invisible text layer`.

### Task B.2: VisionOCR + OCREngine + OCRView
**Depends:** B.1, 0.3

**Interfaces:**
- Produces: `struct VisionOCR { func recognise(_ image: CGImage) async throws -> [PositionedText] }` (VNRecognizeTextRequest, `.accurate`, on-device, language auto). Render each page to CGImage at ≥300 DPI for OCR (spec M10 default).
- Produces: `struct OCREngine { func ocr(_ input: URL, to output: URL, progress:(Double)->Void) async throws -> OCRResult }` — for each page: if page already has a text layer (spec M11: skip `.mixed`/text pages), keep as-is; else render→VisionOCR→collect PositionedText; then `PDFWriter.appendTextLayer`. `struct OCRResult { let pagesOCRd: Int; let pagesSkipped: Int }`.

- [ ] Step 1: Failing `OCREngineTests` — OCR an `imagePDF()` whose image contains rendered text "HELLO WORLD"; assert output has extractable "HELLO WORLD" and skipped-count for a born-digital page.
- [ ] Step 2: Implement `VisionOCR`, `OCREngine`. Tests PASS.
- [ ] Step 3: `OCRView` + `OCRViewModel` derived from the design system: drop zone, run button, per-file state, result. Commit `feat: Apple Vision OCR tool with searchable-layer output`.

### Track C — Compress depth (batch, estimate, presets UI). Model: Sonnet. Files: `Shared/ToolQueue.swift`, `Compress/CompressEstimator.swift`, and additive edits to `CompressView.swift`/`CompressViewModel.swift` (coordinated: Track C owns these two after M1; Track B/D do not touch them).

### Task C.1: ToolQueue (batch)
**Depends:** 0.3

**Interfaces:**
- Produces: `@MainActor final class ToolQueue: ObservableObject { @Published var jobs: [ToolJob]; func add(_ urls: [URL]); func removeCompleted(); func run(using: (ToolJob) async -> Void, maxConcurrent: Int) async; func cancel() }` — bounded concurrency (default 2), cancellable, per-job progress. Cancelled jobs leave no partial output (temp-file discipline lives in the engines).

- [ ] Step 1: Failing `ToolQueueTests` — add 5 jobs, run with a stub that flips state, assert all done; cancel mid-run leaves remaining queued.
- [ ] Step 2: Implement. Tests PASS. Commit `feat: batch ToolQueue with bounded concurrency and cancellation`.

### Task C.2: CompressEstimator (per-file, time-boxed)
**Depends:** 0.4

**Interfaces:**
- Produces: `struct CompressEstimator { func estimate(_ input: URL, preset: CompressPreset) async -> SizeEstimate }` — a quick analysis (sample-based: classify + measure image payload ratio) bounded to spec M7 (fall back to typical-range table if median error would exceed ±25% or analysis > 500 ms/file). `struct SizeEstimate { let predictedBytes: Int; let confidence: Confidence; let isFallback: Bool }`.

- [ ] Step 1: Failing test — estimate returns within time box; fallback flagged when analysis times out (inject a slow classifier).
- [ ] Step 2: Implement. Tests PASS. Commit `feat: time-boxed per-file compression estimate`.

### Task C.3: Wire batch + presets + estimate into CompressView
**Depends:** C.1, C.2

- [ ] Step 1: Extend `CompressView`/`CompressViewModel` — multi-file drop, per-file rows with estimate → live progress → real before/after, preset picker, optional output-folder picker, cancel. Build + launch, run a 3-file synthetic batch through the GUI.
- [ ] Step 2: Commit `feat: batch compress UI with presets, estimates, output folder`.

### Track D — Design system + polish. Model: Sonnet. Files: `DesignSystem/Theme.swift`, `DesignSystem/Components.swift`, and the visual layer only. Coordinated: Track D owns `DesignSystem/*`; view files are owned by B/C — Track D delivers reusable components + tokens that B/C consume. To avoid races, Track D runs its component/token work in parallel, and a short serial polish pass (orchestrator) applies them to the views after B and C land.

### Task D.1: Design tokens + components from DESIGN.md + Claude Design output
**Depends:** 0.1

**Interfaces:**
- Produces: `enum Theme { static let colours…; static let type…; static let spacing…; static let radius… }` from `DESIGN.md` (bg `#f5f5f7`, text `#1d1d1f`/`#000`, accent `#0071e3`, pill radius, SF Pro Display ≥20 / Text <20, soft sparse shadow), light + dark.
- Produces: `Components.swift` — `PrimaryButton` (pill), `Card`, `DropZone`, `StatPill`, `SegmentedPreset`, `FileRow`, matching the Claude Design output at `<private design mockup>/` (rebuilt faithfully, not pixel-copied; §7 deviations: 4-entry sidebar, stats widget cut for v1).

- [ ] Step 1: Implement `Theme` + `Components` with SwiftUI previews (light + dark). No test target (visual); verify via preview render / screenshot.
- [ ] Step 2: Commit `feat: design system tokens and reusable components (Apple DESIGN.md)`.

---

# PHASE 2 — Integrate, validate, ship. Track: `ship`. Model: Opus (orchestrator-led).

### Task S.1: Design polish pass
- [ ] Apply `Theme`/`Components` across `CompressView`, `OCRView`, `RootView`, `SidebarView`; states (empty, queued, analysing, running, done, error) all styled; light + dark verified. Commit.

### Task S.2: Integration + real-corpus quality validation
- [ ] Full test suite green (`xcodebuild test`).
- [ ] Build the app; run the **local quality harness** on the real corpus at `<private local corpus>` (authorised): for each PDF, compress at each preset + OCR the image-only ones; record size-reduction % and a quality spot-check (render-diff sanity). **Report anonymised aggregates only** (avg/median reduction by content type; OCR success rate). Write results to the LCW ledger (uncommittable) — NEVER to the repo.
- [ ] If reduction is weak, tune Rung-1 gs params (within spec §5 bounds) and re-measure. Commit any param tuning.

### Task S.3: Review-team gate
- [ ] Run the review-team runbook (`skills/review-team/SKILL.md`) on the branch: 4 lenses (spec-fidelity, correctness, security, elegance), loop to SHIP, fix/rebut every minor. Record rounds in the ledger. On stop-red, climb the recovery ladder (diagnose/resume → panel), don't loop forever.

### Task S.4: DMG packaging + Gatekeeper reality test
- [ ] `scripts/package-dmg.sh`: `xcodebuild archive` → export → deep ad-hoc sign (`codesign -s - --options runtime --deep`) → `hdiutil` DMG.
- [ ] Empirically verify open-flow: mount DMG, drag to /Applications, launch (confirm window + a real compress works). Then set `com.apple.quarantine` xattr (simulate download), retry, capture the exact Gatekeeper failure + the one-time bypass (`xattr -dr com.apple.quarantine` / right-click→Open). Document precise steps for the morning report.

### Task S.5: GitHub Actions CI
- [ ] `.github/workflows/build.yml` on `macos-15` (or latest): install xcodegen, run `build-ghostscript.sh` (cached), `xcodegen generate`, `xcodebuild test`, `xcodebuild archive`, ad-hoc sign, build DMG, upload as artifact. A `release` job (tag-triggered) publishes the DMG to a GitHub Release. Notarise + Developer-ID-sign steps present but **guarded on `secrets.APPLE_*` being set** (skipped until user adds credentials).
- [ ] Push branch; confirm the CI run goes green on GitHub (fix until it does).

### Task S.6: PR, merge, retro
- [ ] Push `feat/pdf-toolbox-v1`. Open PR referencing the spec path. KB update (kb-updater diff mode) + Check-2b receipt satisfied by S.3's review-team SHIP.
- [ ] **Merge the PR into `main` myself** (user's explicit standing authorisation), push.
- [ ] Retro: mine review-round footers → update/create `.claude/memory/review-lessons.md` (LC-A…LC-E + any new), commit on branch pre-merge (or a follow-up commit + push post-merge).
- [ ] Write the morning report: what works + evidence (real reduction numbers), what's deferred (Rung 2/3) + why, what's blocked on the user (Apple Developer cert for notarisation), copy-paste DMG test steps.

---

## Deferred (stretch — only if core lands with hours to spare)
- **Rung 2:** jbig2enc (JBIG2, lossless bilevel) + CCITT G4 fallback + PDF image-XObject splicing via PDFWriter. Router already has the seam.
- **Rung 3:** MRC port (segmentation spike first; ship without if inadequate).

These are NOT part of tonight's DoD. The router in `CompressEngine` sends all content types to Rung-1 gs until/unless these land.

## Self-Review (against spec)
- Spec §5 Compress (Rung 1) → Tasks 0.2/0.4/C.*. §6 OCR → Track B. §4 shell → 0.1/D.1. §7 UI deviations → captured in 0.1 + D.1. §5.4/§11.4 GS sandbox → 0.2 SeatbeltProfile. §5.3 estimate → C.2. Output safety (temp+rename, never-bigger, validation) → 0.4. §9 build → 0.1 + S.5. §11.5 GS bundle risk → 0.2 (proven by spike). DoD floor (Rung 1 + OCR) → Phase 0 + Track B.
- Rungs 2/3 deferred per spec's own allowance (M13 fix: Rung 1 = v1-done floor).
- No placeholders: every task names files, interfaces, and test assertions. Code sketches given for the subtle parts (sandbox profile, incremental append, coordinate contract); full implementation is the subagent's, guided by the spec.
