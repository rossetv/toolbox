# PDF Toolbox v1 — Implementation Plan (v3 — SHIP, gated R1→R3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS app, **PDF Toolbox**, with two working tools — **Compress** (Ghostscript-core, Rung 1) and **OCR** (Apple Vision) — in an extensible SwiftUI shell, packaged as an ad-hoc-signed DMG with GitHub Actions CI.

**Architecture:** Depth-first. A serial vertical slice (Phase 0) builds the **complete shared layer** (§4) — models, PDFService, GhostscriptRunner+sandbox, ToolQueue, FileNaming — plus Rung-1 compress wired end-to-end, and proves it works at the **M1 gate** (launch → compress → validate). Only then does Phase 1 fork into breadth tracks (OCR, compress-depth, design) that *consume settled interfaces*, never build shared modules in parallel. Phase 2 integrates, validates on the real corpus, gates, and ships.

**Tech Stack:** SwiftUI, Swift 5.9+, macOS 14+ (Apple Silicon), XcodeGen + xcodebuild, bundled Ghostscript 10.07.1 (arm64, built from source per the spike recipe), Apple Vision (`VNRecognizeTextRequest`), PDFKit, `sandbox-exec` (seatbelt) for GS containment. Licence AGPL-3.0.

**Spec:** `.claude/specs/20260722-pdf-toolbox-v1.md` (approved 2026-07-22) — law; on any conflict the spec wins.
**Plan-gate R1 findings addressed:** `.git/lcw/20260722-pdf-toolbox-v1/plan-review-r1.md` (11 major + 18 minor). Resolution notes inline as `[M#]`/`[m#]`.

## Global Constraints

- **Platform:** macOS 14.0 minimum deployment target; Apple Silicon (arm64). Built with Xcode 26.6 / macOS 26 SDK.
- **Licence:** AGPL-3.0. **Every new source file carries a short AGPL header** `[m13]`. Repo private during dev, public at release.
- **Build:** XcodeGen generates `PDFToolbox.xcodeproj` from `project.yml`; `xcodebuild` drives builds. `project.yml` uses **directory/glob source discovery** (no explicit file lists) so Phase-1 tracks add files without editing it `[m6]`. `.xcodeproj` is generated (git-ignored), regenerated locally + in CI.
- **Ghostscript:** built from source by `scripts/build-ghostscript.sh` (spike recipe) into `Resources/ghostscript/`, which is **git-ignored, not committed** `[m15]` (a 26 MB arm64 binary must not bloat an open-source repo's history). A fresh clone / CI runs the script before building the app.
- **Signing:** ad-hoc only (`codesign -s -`) — no Developer ID cert available. Hardened runtime enabled. Notarisation deferred (needs user's Apple Developer credentials); CI notarise step guarded on secrets.
- **Naming/copy:** Product "PDF Toolbox". Outputs `<name>-compressed.pdf` / `<name>-ocr.pdf` next to the original (batch: optional output-folder picker). British English in prose/comments/commits; code identifiers follow platform/library spelling.
- **Privacy (HARD):** Never commit anything about the user's personal test PDFs at `<private local corpus>` — no path, names, sizes-tied-to-names, contents, or subject matter. Committed fixtures are synthetic only. Local quality validation on the real corpus reports anonymised aggregates only, to the ledger (uncommittable), never the repo.
- **GS containment `[M5]`:** every Ghostscript invocation runs under `sandbox-exec` with a profile that **`(import "system.sb")` + `(import "bsd.sb")`** (so the dynamically-linked binary can launch: dyld, `/usr/lib`+`/System/Library` reads, `com.apple.dyld` mach-lookup, `sysctl-read`, `/dev/urandom`), **`(allow process-exec* (literal "<gsPath>"))`** (empirically required `[MAJOR-A]` — without it `sandbox-exec` refuses to exec gs, `execvp Operation not permitted`), **then `(deny network*)`** and **scopes file-read/write to the specific input, output, and temp paths** (the gs binary's own dir MUST be inside the `file-read*` scope) — plus `-dSAFER` and resource caps. Never a bare `Process`. (Empirically verified this round: with the imports + `process-exec*` + scoped `file-read*`, gs launches and a read outside the scope is still denied — the FS confinement is real.)
- **Output safety:** compress/OCR write to a temp file **in the output directory** (same volume, so atomic rename cannot cross-device-fail `[m5]`) then atomically rename; never overwrite the input; compress never emits a file larger than the input — on no-gain, **keep the original, surface "already optimised", and write NO redundant copy** `[m4-minor]`; every output re-validated before it is called done.
- **Memory `[m14]`:** page rasterisation (OCR render, compress render-sample) is **per-page render-then-release**, never all-pages-in-memory — must survive a 1000-page scan.
- **Progress `[m10-minor]`:** never fabricate a percentage. Compress parses `gs` page markers on stdout for real progress, else shows **indeterminate**; OCR reports real per-page progress.
- **DoD floor:** v1 is "done" with **Rung 1 Compress + OCR** working, tested, DMG'd. Rung 2 (jbig2enc/CCITT) and Rung 3 (MRC) are explicitly deferred stretch — attempted only if the core lands with hours to spare, never at the cost of polish or stability. (Spec §13's literal "Rungs 1–2" wording is superseded by its own M13 fix setting Rung 1 as the floor — confirmed by the approval dispatch.)

---

## File Structure

```
toolbox/
  project.yml                          XcodeGen (glob sources; app + tests targets)
  LICENSE                              AGPL-3.0
  .gitignore                           + Resources/ghostscript/, *.xcodeproj, .build
  .claude/GATES.md                     the gates that define "done"  [M8]
  scripts/
    build-ghostscript.sh               reproducible gs build (spike recipe; local + CI)
    package-dmg.sh                     archive → ad-hoc sign → DMG
  Sources/PDFToolbox/
    App/            PDFToolboxApp.swift RootView.swift SidebarView.swift Tool.swift
    DesignSystem/   Theme.swift (0.1 stub → D.1 full)  Components.swift (D.1)
    Models/         ToolJob.swift  JobOutcome.swift  CompressPreset.swift  PDFContentType.swift  SizeEstimate.swift
    Services/       PDFService.swift  GhostscriptRunner.swift  SeatbeltProfile.swift  PDFWriter.swift  OutputValidator.swift  OpenGuard.swift
    Shared/         ToolQueue.swift  FileNaming.swift  Log.swift  SystemInfo.swift
    Compress/       CompressEngine.swift  CompressEstimator.swift  CompressView.swift  CompressViewModel.swift
    OCR/            VisionOCR.swift  OCREngine.swift  OCROptions.swift  OCRView.swift  OCRViewModel.swift
  Resources/ghostscript/               (git-ignored; built)
  Tests/PDFToolboxTests/
    Fixtures.swift  (bornDigital / image / bilevel / textImage / encrypted / corrupt)
    PDFServiceTests.swift  SeatbeltRunTests.swift  CompressEngineTests.swift
    OutputValidatorTests.swift  PDFWriterTests.swift  OCREngineTests.swift
    ToolQueueTests.swift  FileNamingTests.swift  EstimatorTests.swift
  .github/workflows/build.yml          CI
```

---

# PHASE 0 — Foundation spine (SERIAL — the M1 gate). Track: `spine`. Model: Opus.

One dependency chain, orchestrator-led. Builds the **entire §4 shared layer** so Phase-1 tracks only consume it. Ends at **M1: app launches, compresses a synthetic PDF under the sandbox, saves a validated `-compressed.pdf`.** No Phase-1 track starts until M1 is committed.

### Task 0.1: XcodeGen project + launching shell + GATES.md
**Track:** spine · **Model:** Opus · **Depends:** none

**Files:** Create `project.yml` (glob sources), `LICENSE`, `.gitignore`, `.claude/GATES.md`, `App/*`, `DesignSystem/Theme.swift` (token stub).

**Interfaces — Produces:** `enum Tool: String, CaseIterable, Identifiable { case compress, ocr, merge, split }` with `title`, `systemImage`, `isAvailable` (compress/ocr true; merge/split shown disabled = "Soon" per spec §7 — a 4-entry sidebar). `RootView` owns `@State selectedTool: Tool`.

- [ ] Step 1: `project.yml` — app target `PDFToolbox` (bundleId `com.pdftoolbox.app`, deploy 14.0, arm64, hardened runtime), test target `PDFToolboxTests`; **glob-based sources** (`Sources/PDFToolbox`, `Tests/PDFToolboxTests`) `[m6]`; `Resources/` folder reference so `Resources/ghostscript/` bundles. `.gitignore` adds `Resources/ghostscript/`, `*.xcodeproj`, `.build/`, `DerivedData/`.
- [ ] Step 2: `PDFToolboxApp.swift` (`@main`, `WindowGroup { RootView() }`, min 900×620), `RootView` (`NavigationSplitView`), `SidebarView`, `Tool.swift`. AGPL `LICENSE` + per-file headers.
- [ ] Step 3: `.claude/GATES.md` `[M8]` — the commands that define "done": `xcodegen generate`; `xcodebuild -scheme PDFToolbox build`; `xcodebuild test`; `scripts/build-ghostscript.sh` succeeds + produces `Resources/ghostscript/bin/gs`; `scripts/package-dmg.sh` produces a mountable DMG. (KB itself bootstrapped in Phase 2 once modules exist.)
- [ ] Step 4: `xcodegen generate` → `xcodebuild -scheme PDFToolbox build` → BUILD SUCCEEDED. Launch (smoke): window + 4-entry sidebar appears; kill.
- [ ] Step 5: Commit `feat: scaffold app shell (XcodeGen glob project, SwiftUI shell, GATES.md)`.

### Task 0.2: Bundle Ghostscript + sandboxed GhostscriptRunner (with a REAL sandboxed-compress test)
**Track:** spine · **Model:** Opus · **Depends:** 0.1

**Files:** Create `scripts/build-ghostscript.sh` (verbatim spike recipe below), `Services/GhostscriptRunner.swift`, `Services/SeatbeltProfile.swift`, `Tests/…/SeatbeltRunTests.swift`.

**Spike recipe (proven — VERDICT YES, single 26 MB system-dylibs-only binary):**
```sh
curl -sSL -o gs.tar.xz https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/ghostscript-10.07.1.tar.xz
tar xf gs.tar.xz && cd ghostscript-10.07.1
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
  ./configure --prefix="$PWD/../install" --disable-fontconfig --disable-dbus --disable-cups --without-tesseract --without-x
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= make -j"$(sysctl -n hw.ncpu)"
# → ./bin/gs (arm64, minos 14.0, ~26 MB, otool -L = libSystem + libiconv only, Resource tree in ROM)
```
Both env knobs are MANDATORY (deployment-floor + Homebrew-blinding). Copy `bin/gs` → `Resources/ghostscript/bin/gs`.

**Interfaces — Produces:**
- `enum SeatbeltProfile { static func profile(gsPath: URL, readPaths: [URL], writePaths: [URL]) -> String }` — string begins `(version 1)(import "system.sb")(import "bsd.sb")(allow process-exec* (literal "<gsPath>"))(deny network*)` then `(allow file-read* (subpath "<gsDir>") (literal <inputs>))(allow file-write* (subpath "<tmpDir>") (literal <outputs>))` — where `<gsDir>` (containing the gs binary) is always included in the read scope `[M5][MAJOR-A]`.
- `struct GhostscriptRunner { init() throws; func run(arguments: [String], readPaths: [URL], writePaths: [URL], onProgress: ((Int)->Void)?) throws -> ProcessResult }` — locates bundled `gs`, wraps in `sandbox-exec -p <profile>` (or `-f`), applies `-dSAFER` + caps, parses page markers for progress `[m10]`. **`[MINOR-F]` Canonicalise the gs path once (`URL(fileURLWithPath:).resolvingSymlinksInPath()` / `realpath`) and use that SAME canonical string both as the exec target and as the profile's `process-exec` literal** — a symlink mismatch (e.g. `/var` vs `/private/var`) between the two silently yields `execvp Operation not permitted`. `struct ProcessResult { let exitCode: Int32; let stdout, stderr: String }`.

- [ ] Step 1: Commit `build-ghostscript.sh`; run it → populate `Resources/ghostscript/`. Verify `Resources/ghostscript/bin/gs --version` under `env -i`.
- [ ] Step 2: `SeatbeltProfile.swift` per `[M5]`. Unit-test: generated string contains both imports, `(allow process-exec*`, `deny network*`, the gs binary dir in the read scope, and the scoped paths.
- [ ] Step 3: **`SeatbeltRunTests` — the M1-critical positive test:** generate an `imagePDF()` fixture, run a REAL `gs -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook` through `GhostscriptRunner` (i.e. under `sandbox-exec`), assert exit 0 AND output is a smaller valid PDF `[M5]`. (Not a string check — proves the sandbox lets gs launch and work.)
- [ ] Step 4: Implement `GhostscriptRunner`; tests PASS.
- [ ] Step 5: Commit `feat: bundle Ghostscript arm64 + sandboxed GhostscriptRunner (seatbelt, real-run tested)`.

### Task 0.3: COMPLETE shared layer — models, PDFService, ToolQueue, open-guard, fixtures
**Track:** spine · **Model:** Opus · **Depends:** 0.1

This is the fix for the R1 root cause: the whole §4 shared layer lands here, before the Phase-1 fork.

**Files:** Create `Models/{ToolJob,JobOutcome,CompressPreset,PDFContentType,SizeEstimate}.swift`, `Services/PDFService.swift`, `Services/OpenGuard.swift`, `Shared/{ToolQueue,FileNaming,Log,SystemInfo}.swift` `[MINOR-I]`, `Tests/…/{Fixtures,PDFServiceTests,ToolQueueTests,FileNamingTests}.swift`.

**Interfaces — Produces:**
- `struct SizeEstimate { let predictedBytes: Int; let confidence: Confidence; let isFallback: Bool }`, `enum Confidence { case high, medium, low }` `[M2]` — defined HERE, C.2 only implements the estimator against it.
- `enum JobOutcome { case compressed(before: Int, after: Int); case noGain(bytes: Int); case ocrAdded(pages: Int, skipped: Int); case alreadySearchable }` `[M4]` — tool-agnostic terminal result.
- `enum JobState { case queued, analysing, running(Double), done(JobOutcome), failed(String) }` `[M4]`.
- `struct ToolJob: Identifiable { let id: UUID; let url: URL; var state: JobState; var resultURL: URL?; var estimate: SizeEstimate? }`.
- `enum CompressPreset: String, CaseIterable { case maximumQuality, balanced, smallestSize }` → `gsArguments()` with a **concrete provisional baseline** `[m1]` from `engine-research-2.md`: per-preset `-dPDFSETTINGS`, explicit `-dColorImageDownsampleType=/Bicubic` + target DPI (300/150/100), `-dAutoFilterColorImages=false -sColorImageFilter=DCTEncode` + per-preset `-dJPEGQ`, `-dSubsetFonts=true -dCompressFonts=true -dDetectDuplicateImages=true -dFastWebView=true`, DCTDecode passthrough; **CMYK policy** `[m2]`: `-dConvertCMYKImagesToRGB=true` on balanced/smallestSize, preserved on maximumQuality. (Numbers retuned against the corpus in S.2.)
- `enum PDFContentType { case bornDigital, mixedColour, scanColour, scanBilevel }` `[m9]` — colour/bilevel scan distinction preserved for Rungs 2/3; **`.scanBilevel` classified content-based** (visually near-two-tone, not raw bit-depth) `[m8]`.
- `struct PDFService { func pageCount(_:) throws -> Int; func classify(_:) throws -> PDFContentType; func pageHasText(_ url: URL, index: Int) throws -> Bool` (via `PDFPage.string` non-empty) `[M3]`; `func renderSample(_ url: URL, pages: Int) throws -> [CGImage]` (per-page render/release `[m14]`) `}`.
- `enum OpenGuard { static func inspect(_ url: URL) throws -> OpenState }`, `enum OpenState { case ok(pageCount: Int); case encrypted; case corrupt }` `[M9]` — up-front detection; both engines call it and prompt-or-skip encrypted, fail corrupt inline.
- `@MainActor final class ToolQueue: ObservableObject { @Published var jobs: [ToolJob]; func add(_ urls: [URL]); func removeCompleted(); func run(_ body: @escaping (ToolJob, _ report: @escaping (Double)->Void) async throws -> JobOutcome, maxConcurrent: Int = SystemInfo.performanceCoreCount) async; func cancel() }` `[M1][MAJOR-B][m12]` — shared by BOTH tools. **ToolQueue owns per-job state**: sets `jobs[i].state = .running(p)` on each `report(p)` callback, `.done(outcome)` on the body's return, and **`.failed(msg)` when the body throws (batch continues — the one failing file fails inline, the rest complete)** `[M9]`. Bounded concurrency defaulting to **performance-core count** `[m12]`; cancellable; cancelled jobs leave no partial output. The engines fit this contract directly: `try await engine.compress(job.url, preset, to: out) { report($0) }`.
- `enum SystemInfo { static var performanceCoreCount: Int }` `[m12]` — reads `sysctl hw.perflevel0.logicalcpu` (Apple Silicon P-cores), falling back to `ProcessInfo.processInfo.activeProcessorCount`.
- `enum FileNaming { static func output(for input: URL, suffix: String, folder: URL?) -> URL }`.

- [ ] Step 1: `Fixtures.swift` — synthetic generators via CoreGraphics: `bornDigitalPDF()`, `imagePDF()` (photo-like), `bilevelPDF()`, **`textImagePDF()`** (a rasterised image containing the rendered words "HELLO WORLD" for OCR tests, so Track B never edits Fixtures) `[m7]`, `encryptedPDF()` (owner/user password), `corruptPDF()` (truncated bytes). Never read disk.
- [ ] Step 2: Failing `PDFServiceTests` — pageCount==3 on a 3-page fixture; classify(bornDigital)==.bornDigital, classify(image)==.scanColour; `pageHasText` true on born-digital page, false on image page; `OpenGuard.inspect(encrypted)`==.encrypted, `.inspect(corrupt)`==.corrupt.
- [ ] Step 3: Implement all models + `PDFService` + `OpenGuard` + `FileNaming` + `Log`. Tests PASS. **Verify the module compiles standalone** (no forward refs to Phase-1 types) `[M2]`.
- [ ] Step 4: Failing `ToolQueueTests` — add 5 jobs, `run` with a stub returning `.compressed(1,1)` flips all to `.done`; a stub that calls `report(0.5)` sets that job `.running(0.5)` before `.done`; **a stub that throws on one job sets THAT job `.failed` while the other four still reach `.done` (batch continues)** `[MAJOR-B][M9]`; `cancel` mid-run leaves remaining queued, no partial output. Failing `FileNamingTests` — suffix, collision `-compressed-1.pdf`, folder override. Implement; PASS.
- [ ] Step 5: Commit `feat: complete shared layer — models, PDFService+OpenGuard, ToolQueue, fixtures`.

### Task 0.4: Rung-1 CompressEngine + OutputValidator + end-to-end UI wire (M1 GATE)
**Track:** spine · **Model:** Opus · **Depends:** 0.2, 0.3

**Files:** Create `Services/OutputValidator.swift`, `Compress/{CompressEngine,CompressView,CompressViewModel}.swift`, `Tests/…/{OutputValidatorTests,CompressEngineTests}.swift`.

**Interfaces — Produces:**
- `struct OutputValidator { func validate(input: URL, output: URL, samplePages: Int) throws -> Bool }` — page counts equal AND N sample pages **render without error and are non-blank**; does NOT pixel-compare against input (lossy output legitimately differs) `[m3]`.
- `struct CompressEngine { init(runner: GhostscriptRunner, service: PDFService); func compress(_ input: URL, preset: CompressPreset, to output: URL, progress: @escaping (Double)->Void) async throws -> JobOutcome }` — `OpenGuard.inspect` first (throw/skip on encrypted/corrupt); route all content types to Rung-1 gs for v1 (router seam present, one impl); temp-file in output dir + atomic rename; never-bigger guard → on no-gain return `.noGain(bytes:)` and **do not write an output file** `[m4-minor]`; `OutputValidator` before success; returns `.compressed(before:after:)`.

- [ ] Step 1: Failing `OutputValidatorTests` (equal-count non-blank → pass; count mismatch → fail; blank page → fail).
- [ ] Step 2: Implement `OutputValidator`; PASS.
- [ ] Step 3: Failing `CompressEngineTests` — compress `imagePDF()` at `.balanced` → `.compressed` with after<before, count preserved, validated; `bornDigitalPDF()` (tiny) → `.noGain`, no output file written; `encryptedPDF()` → throws/`.failed`.
- [ ] Step 4: Implement `CompressEngine`; PASS.
- [ ] Step 5: Wire `CompressView` + `CompressViewModel` (single-file: drop/pick, preset control, Compress button, before/after row) onto `ToolQueue`. Build, launch, compress a synthetic PDF via GUI → validated `-compressed.pdf` appears.
- [ ] Step 6: **M1 GATE.** Commit `feat: Rung-1 Ghostscript compress wired end-to-end under sandbox (M1)`. Ledger: M1 green.

---

# PHASE 1 — Breadth (parallel after M1). Tracks B/C/D, file-disjoint, each in its own worktree.

**Worktree-isolation rule `[M11]`:** each track runs in its own worktree off the feature branch. `DesignSystem/Components.swift` (Track D) does NOT exist in B's or C's worktree during Phase 1. Therefore **Tracks B and C reference ONLY the Task 0.1 `Theme` stub** (present at the fork) — never `Components` symbols. ALL `Components` application to views is deferred to the serial S.1 polish pass. Track file ownership is disjoint: B owns `OCR/*` + `Services/PDFWriter.swift`; C owns `Compress/CompressEstimator.swift` + additive edits to `Compress/CompressView.swift`/`CompressViewModel.swift`; D owns `DesignSystem/*`. ToolQueue/PDFService/models are settled (Phase 0) — consumed, never mutated.

### Track B — OCR tool. Model: Opus (Vision + PDF incremental append is subtle).

### Task B.1: PDFWriter — incremental-update invisible text layer
**Depends:** 0.3

**Interfaces — Produces:**
- `struct PositionedText { let text: String; let boundingBox: CGRect /* Vision-normalised, origin bottom-left, 0…1 */ }` `[M7]`.
- `struct PageGeometry { let mediaBox: CGRect; let rotation: Int }`.
- `struct PDFWriter { func appendTextLayer(to input: URL, output: URL, pageText: [Int: [PositionedText]], geometry: [Int: PageGeometry]) throws }` `[M7]` — **PDFWriter owns the coordinate transform**: normalised box → PDF user space accounting for `mediaBox` origin + `rotation`. Uses PDF incremental update (original bytes verbatim; appended objects + xref delta + trailer `/Prev`). Invisible text via render mode 3, Helvetica, sized to bbox.
- **Invariant `[M6]`:** image XObject streams remain byte-identical; each OCR'd page dict is *superseded* (appends the invisible-text content stream to `/Contents`, adds a font to `/Resources`); rendered appearance unchanged (validated by render-diff, not byte-identity).

- [ ] Step 1: Failing `PDFWriterTests` — append "HELLO" to `imagePDF()`; reopen → text extractable; **image XObject stream bytes unchanged** (the correct invariant); page count preserved; a render-diff of the page shows no visible change.
- [ ] Step 2: Implement incremental append + the normalised→user-space transform (test a 90°-rotated page maps correctly). PASS.
- [ ] Step 3: Commit `feat: PDFWriter incremental-update invisible OCR text layer`.

### Task B.2: VisionOCR + OCROptions + OCREngine + OCRView (batch + options panel)
**Depends:** B.1, 0.3

**Interfaces — Produces:**
- `struct OCROptions { var accuracy: Accuracy = .accurate; var languages: [String] = [] /* empty = auto */ }`, `enum Accuracy { case fast, accurate }` `[M10]`.
- `struct VisionOCR { func recognise(_ image: CGImage, options: OCROptions) async throws -> [PositionedText] }` `[M10]` — `VNRecognizeTextRequest`, `.recognitionLevel` from accuracy, `recognitionLanguages` from options, on-device; boxes returned Vision-normalised (NOT transformed) `[M7]`. Page rendered at ≥300 DPI, per-page render/release `[m14]`.
- `struct OCREngine { func ocr(_ input: URL, to output: URL, options: OCROptions, progress: @escaping (Double)->Void) async throws -> JobOutcome }` `[M10]` — `OpenGuard.inspect` first; for each page: `PDFService.pageHasText` true → skip `[M3]`; else render → `VisionOCR.recognise` → collect. Then `PDFWriter.appendTextLayer` (with geometry) → temp+rename+`OutputValidator` `[m11]`. Returns `.ocrAdded(pages:skipped:)`, or `.alreadySearchable` if every page had text.

- [ ] Step 1: Failing `OCREngineTests` — OCR `textImagePDF()` → output has extractable "HELLO WORLD"; born-digital page reported skipped; a fully-text PDF → `.alreadySearchable`.
- [ ] Step 2: Implement `OCROptions`, `VisionOCR`, `OCREngine`; PASS.
- [ ] Step 3: `OCRView` + `OCRViewModel` on `ToolQueue` (batch, like Compress) with an **options panel (accuracy toggle + language)** `[M10]`, styled with the `Theme` stub only `[M11]`. Commit `feat: Apple Vision OCR tool — batch, options panel, searchable-layer output`.

### Track C — Compress depth (estimate + batch/preset UI). Model: Sonnet (C.1/C.2; ToolQueue already Opus-built in Phase 0 `[m18]`).

### Task C.1: CompressEstimator (per-file, time-boxed)
**Depends:** 0.4

**Interfaces — Produces:** `struct CompressEstimator { func estimate(_ input: URL, preset: CompressPreset) async -> SizeEstimate }` — sample-based analysis (classify + image-payload ratio) bounded per spec M7: fall back to a typical-range table (flag `isFallback`, lower `confidence`) if analysis would exceed **±25 % median error or 500 ms/file**.

- [ ] Step 1: Failing `EstimatorTests` — returns within the time box; fallback flagged when a slow classifier is injected.
- [ ] Step 2: Implement; PASS. Commit `feat: time-boxed per-file compression estimate`.

### Task C.2: Wire batch + presets + estimate into CompressView
**Depends:** C.1

- [ ] Step 1: Extend `CompressView`/`CompressViewModel` — multi-file drop, per-file rows (estimate → live progress → real before/after), preset picker, optional output-folder picker, cancel. `Theme` stub only `[M11]`. Build + launch, run a 3-file synthetic batch via GUI.
- [ ] Step 2: Commit `feat: batch compress UI with presets, estimates, output folder`.

### Track D — Design system. Model: Sonnet.

### Task D.1: Theme (full) + Components from DESIGN.md + Claude Design output
**Depends:** 0.1

**Interfaces — Produces:** `enum Theme` (full tokens from `DESIGN.md`: bg `#f5f5f7`, text `#1d1d1f`/`#000`, accent `#0071e3`, pill radius 980, SF Pro Display ≥20 / Text <20, soft sparse shadow; light + dark). `Components.swift` — `PrimaryButton`(pill), `Card`, `DropZone`, `StatPill`, `SegmentedPreset`, `FileRow` — rebuilt faithfully (not pixel-copied) from the Claude Design output at **`the Claude Design mockup (kept outside this repository)`** (+`support.js`) `[m16]`; §7 deviations: 4-entry sidebar, stats widget cut for v1.

- [ ] Step 1: Implement `Theme` + `Components` with light+dark SwiftUI previews; verify via preview render/screenshot.
- [ ] Step 2: Commit `feat: design system tokens + reusable components (Apple DESIGN.md)`.

---

# PHASE 2 — Integrate, validate, ship. Track: `ship`. Model: Opus (orchestrator-led).

### Task S.1: Design polish pass `[M11]`
- [ ] Merge Tracks B/C/D to the feature branch. Apply `Theme`/`Components` across `CompressView`, `OCRView`, `RootView`, `SidebarView`; style all states (empty, queued, analysing, running, done, already-optimised/already-searchable, error) `[M4/M9]`; light + dark verified. Commit.

### Task S.2: Integration + real-corpus quality validation `[m17]`
- [ ] Full suite green (`xcodebuild test`).
- [ ] Run the local quality harness on the real corpus at `<private local corpus>` (authorised): each PDF × each preset compress + OCR the image-only ones; record size-reduction % + render-diff quality spot-check. **Acceptance target `[m17]`: Rung-1 meets or beats stock-GS `/ebook` reduction on the corpus, with no visible quality regression at `.balanced`.** Report anonymised aggregates only, to the ledger. NEVER to the repo.
- [ ] If below target, retune `CompressPreset` gs params (within spec §5 bounds) and re-measure. Commit tuning.

### Task S.3: Review-team gate
- [ ] Run the review-team runbook (4 lenses: spec-fidelity, correctness, security, elegance), loop to SHIP, fix/rebut every minor, record rounds in the ledger. On stop-red, climb the recovery ladder (diagnose/resume → panel) — don't loop forever.

### Task S.4: DMG packaging + Gatekeeper reality test
- [ ] `scripts/package-dmg.sh`: `xcodebuild archive` → export → **deep ad-hoc sign** (`codesign -s - --options runtime --deep`, incl. the bundled `gs`) → `hdiutil` DMG.
- [ ] Empirically verify: mount DMG, drag to /Applications, launch, run a real compress + a real OCR. Then set `com.apple.quarantine` (simulate download), retry, capture the exact Gatekeeper failure + one-time bypass (`xattr -dr com.apple.quarantine` / right-click→Open). Document precise steps for the morning report.

### Task S.5: KB bootstrap + GitHub Actions CI
- [ ] **KB bootstrap FIRST — before any push `[MINOR-C]`.** Bootstrap a minimal `.claude/` KB (OVERVIEW, INDEX, ARCHITECTURE, module docs) describing the now-real modules `[M8]` + a DECISIONS.md entry for the engine/licence/build decisions; commit it. The push/PR KB gate requires the KB present, so this must precede the first branch push below.
- [ ] `.github/workflows/build.yml` on `macos-15`: install xcodegen; run `build-ghostscript.sh` (cache the built binary by source hash); `xcodegen generate`; `xcodebuild test`; `xcodebuild archive`; ad-hoc sign; `package-dmg.sh`; upload DMG artifact. A tag-triggered `release` job publishes the DMG to a GitHub Release. Developer-ID-sign + notarise steps present but **guarded on `secrets.APPLE_*`** (skipped until the user adds credentials). Belt-and-braces: a smoke job that launches the built app (or at least runs the bundled `gs --version`) to confirm the 14.0-target binary runs.
- [ ] Push branch (KB already committed); iterate until the CI run is green on GitHub.

### Task S.6: PR, merge, retro
- [ ] Open PR referencing the spec path (branch already pushed in S.5 with the KB present). Check-2b receipt satisfied by S.3's review-team SHIP.
- [ ] **Merge the PR into `main` myself** (user's explicit standing authorisation), push.
- [ ] Retro: mine all review-round footers (spec R1–R2, plan R1–R3, review-team rounds) → create/update `.claude/memory/review-lessons.md` (LC-A…E, LC-P1…P7, + any new) `[MINOR-H]`; commit on branch.
- [ ] Morning report: what works + evidence (real reduction numbers), what's deferred (Rung 2/3) + why, what's blocked on the user (Apple Developer cert → notarisation), copy-paste DMG test steps.

---

## Deferred (stretch — only if core lands with hours to spare)
- **Rung 2:** jbig2enc (JBIG2 lossless bilevel) + CCITT G4 fallback + PDF image-XObject splicing via PDFWriter. Router seam present.
- **Rung 3:** MRC port (segmentation spike first; ship without if inadequate).
Not part of tonight's DoD; the router sends all content to Rung-1 gs until they land.

## R1 finding coverage
M1→ToolQueue in 0.3, wired both tools (0.4, B.2). M2→SizeEstimate/Confidence in 0.3. M3→`pageHasText` in 0.3. M4→JobOutcome/JobState in 0.3. M5→SeatbeltProfile imports + real sandboxed-compress test (0.2). M6→invariant restated (B.1). M7→VisionOCR normalised / PDFWriter transforms w/ geometry (B.1,B.2). M8→GATES.md (0.1) + KB (S.5). M9→OpenGuard (0.3). M10→OCROptions + panel (B.2). M11→Theme-stub-only in B/C, Components applied in S.1. Minors m1–m18 each pinned inline. m18→C.1(ToolQueue) is Phase-0 Opus.

**R2 finding coverage** (`plan-review-r2.md`): MAJOR-A→seatbelt `(allow process-exec* (literal <gsPath>))` added + gs dir in read scope (Global+0.2). MAJOR-B→`ToolQueue.run` body now `(ToolJob, report)->…throws->JobOutcome`; queue owns `.running`/`.done`/`.failed` state, batch continues on throw (0.3 + test). MINOR-C→KB bootstrapped before first push (S.5). MINOR-D→concurrency default = performance-core count via `SystemInfo.performanceCoreCount` (0.3). MINOR-E→Track C header C.1/C.2. Lesson-candidates LC-P5 (validate a sandbox profile by running the binary under it, not string inspection), LC-P6 (a per-job queue closure needs progress + error channels, not just a success return) → retro.
