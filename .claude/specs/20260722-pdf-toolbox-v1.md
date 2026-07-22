# Spec — PDF Toolbox v1 (Compress + OCR)

Date: 2026-07-22 · Branch: `feat/pdf-toolbox-v1` · Status: draft (pre spec-reviewer gate)
Evidence: `./20260722-pdf-toolbox-v1-evidence/` (engine research ×2, native-lib plumbing probe, brainstorm review, design brief)

---

## 1. Origin & goal

The user wants a **native macOS app to compress large PDFs a lot while preserving quality** — private/local, no cloud upload, no subscriptions, an Apple-suite-quality experience. Named a **toolbox** from the outset: compression is the first of several intended PDF utilities. During brainstorm a second v1 tool was added — **OCR** (make image-only PDFs searchable via Apple Vision) — because it validates the extensible shell, reuses Compress's infrastructure, and is fully native/Apple-Silicon.

**Quality bar (explicit user mandate, first-class requirement):** the app must be *best-in-class* at compression, **polished, beautiful, efficient and fast.** "Best result" was explicitly ranked above "purely native" by the user.

## 2. Scope

**In (v1):**
- **Compress** tool — shrink PDFs via a Ghostscript-core engine, 3 quality presets, batch, per-file estimates.
- **OCR** tool — detect PDFs/pages lacking a text layer, add an invisible searchable layer via Apple Vision, batch.
- **Shell** — a macOS sidebar hosting the two tools; Merge/Split shown as dimmed "Soon" placeholders (not built).

**Out (v2+, noted, not built):** Merge, Split, a combined compress+OCR pass, a Finder Quick Action, a target-size mode ("get under 10 MB"), a visual before/after preview. Mac App Store (permanently foreclosed by the AGPL licence — accepted).

## 3. Platform, licence, distribution

- **SwiftUI**, macOS **14 (Sonoma)** minimum, **Apple Silicon** (arm64). Rationale: wide enough for a shared app, modern SwiftUI, and the target machines are M-series.
- **Licence: AGPL-3.0**, **open-source at release.** Forced by two AGPL dependencies chosen for quality/risk reasons: Ghostscript (engine) and the ported Internet-Archive `archive-pdf-tools` (MRC). Consequence: **the Mac App Store is permanently unavailable** (AGPL is App-Store-incompatible) — accepted, because distribution is a **notarised DMG** outside the store. **Repo stays private during development; the user flips it public at/ before release** — AGPL's obligations trigger only on distribution, so private dev is compliant.
- Build: **XcodeGen** (declarative `project.yml` → `.xcodeproj`) driven by `xcodebuild`, so builds/tests run head­lessly from the CLI. Fallback if XcodeGen misbehaves: SwiftPM target + a bundling step (documented risk, §11).
- Native C/C++ dependencies are **statically linked** into the app binary (one Mach-O). **Verified** (evidence/native-lib-plumbing.md): libdeflate built for arm64, linked into a Swift binary via a module map, round-tripped, and code-signed with `--options runtime` and **zero special entitlements** (`codesign -v --strict` clean). No `disable-library-validation`, no `allow-unsigned-executable-memory` needed. Ghostscript, if bundled as a separate executable, is a signed embedded helper invoked via `Process` (not linked).

## 4. Architecture

Three layers; the two tools share most machinery (so OCR is far from double the work).

```
PDF Toolbox (SwiftUI)
├─ Shell            NavigationSplitView sidebar: [Compress] [OCR] [Merge·soon] [Split·soon]
├─ SHARED (built once, used by both tools)
│   ├─ ToolQueue (UI + state)  drag-drop · file list · batch runner · per-file state machine · output control
│   ├─ PDFService             open/save · page inspection · ContentRouter (per page: has-text vs image-only)
│   ├─ VisionOCR              VNRecognizeTextRequest → text + bounding boxes (Neural Engine)
│   └─ TextLayerEmbedder      observations → invisible, selectable PDF text layer
├─ CompressEngine   input PDFs + preset → output PDF + stats; internally staged (GS → +jbig2enc → +MRC)
└─ OCREngine        input PDFs + options → output PDF + stats; router → VisionOCR → TextLayerEmbedder
```

**Module contracts (each independently testable):**
- `ContentRouter.classify(page) -> .text | .imageOnly | .mixed` — pure, from PDFKit page inspection (extractable text present? image coverage?). Shared by Compress (routing) and OCR (which pages need OCR).
- `CompressEngine.compress(url, preset, progress) async throws -> CompressResult` (result = output URL, original/new bytes, per-page notes). No UI knowledge.
- `OCREngine.ocr(url, options, progress) async throws -> OCRResult`.
- `ToolQueue` is generic over a "job" so both tools reuse the queue/batch/state/estimate UI; only the options panel and the run action differ.

**Concurrency:** batch runs jobs concurrently, capped (default = performance-core count, tunable) to stay responsive; each job is cancellable; the UI shows honest per-file + overall progress. GS/native work runs off the main actor.

## 5. Compress tool

### 5.1 Engine — Strategy 1 (Ghostscript-core), staged ladder
Each rung is independently shippable and de-risks the next. Internally the engine is a pipeline behind one interface; the ladder is build order, not user-visible modes.

| Rung | Adds | Target result | Notes / gate |
|---|---|---|---|
| **1** | Tuned Ghostscript `pdfwrite` | Gold-standard general + colour downsample + CCITT B/W | ships an excellent compressor first |
| **2** | jbig2enc (lossless JBIG2) | B/W scans 15–40× (else CCITT G4 5–15×) | **lossless only** (lossy JBIG2 corrupts digits — 2013 Xerox bug); **JBIG2 viewer support must be empirically verified on target macOS before it becomes the default**; CCITT G4 is the universal fallback |
| **3** | MRC — **port** Internet-Archive `archive-pdf-tools` | Beats stock GS on colour/grey scans (5–15×) | preceded by a **segmentation spike** on 5–10 real scans; if segmentation quality is inadequate, ship without Rung 3 (baseline still excellent) |

GS tuning (baseline, from evidence/engine-research-2.md, tuned per content class, then validated on a real corpus): `-dPDFSETTINGS=/ebook` overridden with `/Bicubic` downsampling to a preset-specific DPI, `AutoFilter*=false` to force DCT, `QFactor` per preset, `SubsetFonts/CompressFonts`, `DetectDuplicateImages`, `-dFastWebView`. **DCTDecode passthrough** — do not re-encode already-JPEG images at target DPI (avoids generational artefacts).

### 5.2 Presets (map to GS tuning; exact numbers finalised against a corpus during implementation)
- **Smallest** — aggressive DPI + lower QFactor (email/upload).
- **Balanced** (default) — great size, near-original look.
- **High quality** — light touch, keeps fine detail.

### 5.3 Per-file estimate (user-requested)
Before compressing, a **quick, time-boxed analysis pass** produces a per-file estimate: parse image XObjects (bytes, pixel dimensions → effective DPI, colour space), model the post-preset recompressed size per image + residual, sum. Displayed as an estimate (`~X MB · ~Y% smaller`); the **real** figure replaces it after compression. Constraints: **parse-only, no full encode**; time-boxed per file (coarse-estimate or skip beyond a cap) so a 1000-page scan never stalls the UI; runs async. **Fallback** (if estimates prove too inaccurate or slow in practice): show *typical ranges* per preset instead — documented risk (§11).

### 5.4 Behaviour & safety
- Output `<name>-compressed.pdf` **alongside the original**, optional batch output-folder override, **never overwrite**.
- **Never emit a larger file** — measure output vs input, keep the smaller; if not smaller, mark **"already optimised"** and keep the original.
- **Untrusted-PDF security (mandatory):** input PDFs are untrusted. Run Ghostscript with `-dSAFER` (default in modern GS — assert it), disable unsafe device/file ops, cap memory/time per job, and isolate the GS `Process` so a crash/exploit can't take the app down or escape. Validate that every produced output opens (re-parse via PDFKit) before reporting success.
- **CMYK policy:** preserve or convert per preset (`ConvertCMYKImagesToRGB` for screen presets; avoid colour shifts / broken print intent on high-quality). Finalised during corpus validation.
- **Encrypted/corrupt PDFs:** detect up front; a password-protected PDF prompts (or is skipped with a clear per-file error); a corrupt PDF fails that one file with an inline error and the batch continues.

## 6. OCR tool

- **Detect** per page (via `ContentRouter`): only OCR pages lacking extractable text. A fully-text PDF → **"already searchable — nothing to do."** (A future "force re-OCR" toggle is out of scope.)
- **Recognise** with Apple **Vision** `VNRecognizeTextRequest` on the Neural Engine — for each image-only page, render at a sufficient DPI, recognise text + bounding boxes.
- **Embed** an **invisible, selectable text layer** (`TextLayerEmbedder`) positioned by the Vision bounding boxes — appearance unchanged, the file becomes searchable/selectable.
- **Languages:** automatic detection by default, with an **optional language override** in the options panel (`recognitionLanguages`).
- **Accuracy:** Vision `.accurate` by default, with a **fast/accurate toggle**.
- **Output:** `<name>-ocr.pdf` alongside the original, never overwrite (mirrors Compress).
- OCR **adds a text layer only** — it does not alter images or compress (distinct from Compress). Compress and OCR are **separate tools** in v1 (a combined pass is v2).

## 7. UI

- **Compress UI:** rebuild Claude Design's `Toolbox.dc.html` **pixel-perfect in SwiftUI** (read it in full + its `support.js`; match visual output, not prototype structure). Apple design language per repo `DESIGN.md`.
- **OCR UI:** **derived** from the same design system + Claude Design's realised components — identical shell/queue/batch/state machine, with an **OCR options panel** (language, accuracy) replacing the preset cards and an "OCR N PDFs" action. No separate design round (user-confirmed).
- **Both light and dark mode** (per DESIGN.md). Native macOS controls, SF Symbols, system materials/vibrancy, resizable window, collapsible sidebar.
- **Estimate display** reconciled: the mockup's per-file `% smaller · MB` figures are the §5.3 real estimates (not fabricated). OCR has no size estimate (it adds a layer); it may show a page-count / "N pages to OCR".

## 8. States (both tools, shared state machine)

Empty (drop zone + Choose Files) → Ready (file list + options + estimate + action) → Working (per-file + overall progress, cancellable) → Done (per-file result + summary + Reveal in Finder). Plus per-file **error** and **already-optimised / already-searchable** states. **Progress is honest** — page-based where possible; no fabricated percentages.

## 9. Decisions & rejected alternatives (the whys)

- **Engine = Ghostscript-core, not native.** GS is the gold-standard text-preserving optimiser (font subsetting, object dedup, structure rewrite) and is drop-in low-risk. *Rejected:* pure-Apple native — Apple's PDF write API is only two shapes (PDFKit optimise = one fixed level, not tunable → **can't deliver 3 presets on born-digital PDFs**; rasterise = tunable but flattens text), and it structurally caps on bilevel scans (no JBIG2/CCITT). Verified against SDK headers (`PDFDocument.h`: `saveImagesAsJPEG`/`optimizeImagesForScreen` are booleans; `PDFPage.h`: `compressionQuality` only on the rasterise path). *Rejected:* PDFium-permissive (BSD) — viable and more native, but once AGPL is accepted for MRC it buys nothing GS doesn't, and it forces a from-scratch MRC. *Rejected:* stock GS presets — blunt; we tune per content class.
- **AGPL accepted.** The user chose to open-source at release; that unlocks GS (free) and lets **MRC be a port of proven code** (`archive-pdf-tools`) rather than a from-scratch signal-processing build — collapsing the project's single biggest risk. Cost (MAS foreclosed, un-native engine) accepted because "best result" outranks "native", and distribution is DMG.
- **MRC via port, staged to Rung 3.** Building MRC first would produce a *worse* MRC: segmentation quality is empirical and needs a corpus + measurement harness + router + reassembly (which *are* the baseline). So the baseline ships first; MRC follows, front-loaded by a segmentation spike. (Confirmed by the Fable-5 advisor consult.)
- **Two tools in v1.** OCR validates the extensible shell, is fully native/Vision (balances GS's un-nativeness), and reuses Compress's queue/router/Vision/text-layer infrastructure.
- **UX:** batch queue (real need for "large PDFs" plural); 3 simple presets (Apple-reductive); output alongside + never overwrite + never enlarge (safety); per-file estimate via quick analysis (user-requested).

## 10. Verification evidence (done this session)

- **Engine landscape & licences** — engine-research.md, engine-research-2.md. Licences **confirmed first-hand**: jpegli/libjxl BSD-3 (fetched LICENSE), leptonica BSD-2 (fetched), jbig2enc Apache-2.0, libdeflate MIT, openjpeg BSD-2; Ghostscript AGPL/commercial; archive-pdf-tools AGPL.
- **Apple PDF API limits** — grepped the installed SDK headers (see §9).
- **Native-lib plumbing** — native-lib-plumbing.md: real arm64 build + static link + round-trip + clean codesign. Verdict: low risk.
- **Toolchain present** — Swift 6.3.3, xcodebuild, arm64 SDK.

## 11. Risks & fallbacks

1. **MRC segmentation quality** (top risk) — mitigated by porting a proven reference + an early spike; fallback: ship without Rung 3 (baseline already excellent).
2. **JBIG2 portability** — viewer support unverified on shared recipients; mitigated by empirical verification before defaulting + **CCITT G4 fallback** (universal). Lossless JBIG2 only.
3. **Estimator accuracy/speed** — mitigated by time-boxing + labelling as estimate; fallback: typical ranges per preset.
4. **GS security** (untrusted PDF parsing) — `-dSAFER`, resource caps, process isolation, output re-validation (§5.4).
5. **Notarisation** — needs the user's Apple Developer account + network; documented as a required release step, not a dev blocker.
6. **XcodeGen build tooling** — prove a clean CLI build before feature code; fallback SwiftPM + bundling.
7. **Memory on 1000-page scans** — stream page-by-page, cap concurrency, release buffers; validate on a large scan.

## 12. Milestones (build order)

M0 XcodeGen project + CI-buildable skeleton + empty shell (sidebar, two tool stubs) + `ToolQueue`/`PDFService`/`ContentRouter` + test corpus/harness scaffolding.
M1 Compress Rung 1 (tuned GS, `-dSAFER`, never-enlarge, output validation) + full Compress UI (Claude Design) + estimate pass.
M2 OCR tool (Vision detect → recognise → embed) + derived OCR UI.
M3 Compress Rung 2 (jbig2enc + CCITT, JBIG2 verification gate) — proves native-lib plumbing end-to-end with one lib.
M4 MRC spike → Rung 3 (port) if the spike passes.
M5 Polish pass (animation, empty/error states, keyboard/menus, dark mode), notarised DMG packaging.

## 13. Definition of done (v1)

Both tools work on a real corpus (born-digital, colour scan, B/W scan, mixed, encrypted, corrupt, 1000-page); every output re-opens in Preview + one other viewer; no output larger than input; batch is cancellable with honest progress; UI matches the Claude Design fidelity in light and dark; the app builds/tests/signs from the CLI and packages into a notarisable DMG; gates in `.claude/GATES.md` (to be authored with the first code) are green.
