# Spec — PDF Toolbox v1 (Compress + OCR)

Date: 2026-07-22 · Branch: `feat/pdf-toolbox-v1` · Status: draft (spec-reviewer round 2)
Evidence: `./20260722-pdf-toolbox-v1-evidence/` (engine research ×2, native-lib plumbing probe, brainstorm review, design brief)
Revision note: R2 addresses spec-reviewer R1 (C1 toolchain, M2 GS sandbox, M3 PDF-assembly, M4 OCR mechanism, M5 UI deviations, M6 GS-bundle risk, minors 7–13). Round log in the footer.

---

## 1. Origin & goal

The user wants a **native macOS app to compress large PDFs a lot while preserving quality** — private/local, no cloud upload, no subscriptions, Apple-suite-quality experience. Named a **toolbox** from the outset: compression is the first of several intended PDF utilities. During brainstorm a second v1 tool was added — **OCR** (make image-only PDFs searchable via Apple Vision) — because it validates the extensible shell, reuses Compress's infrastructure, and is fully native/Apple-Silicon.

**Quality bar (explicit user mandate, first-class requirement):** best-in-class compression, **polished, beautiful, efficient, fast.** The user explicitly ranked "best result" above "purely native."

## 2. Scope

**In (v1):** **Compress** (Ghostscript-core engine, 3 presets, batch, per-file estimates); **OCR** (Vision text layer for image-only PDFs, batch); **Shell** (sidebar hosting the two tools; Merge/Split shown as dimmed "Soon" placeholders, not built).

**Out (v2+, noted, not built):** Merge, Split, combined compress+OCR pass, Finder Quick Action, target-size mode, visual before/after preview, a "saved so far" stats widget (§7), per-page routing inside mixed documents (§5.1), jpegli/libdeflate codec upgrades (§5.1). Mac App Store — permanently foreclosed by AGPL, accepted.

## 3. Platform, licence, distribution, build

- **SwiftUI**, macOS **14 (Sonoma)** minimum, **Apple Silicon** (arm64).
- **Licence: AGPL-3.0, open-source at release.** Forced by two AGPL dependencies chosen for quality/risk: Ghostscript (engine) and the ported Internet-Archive `archive-pdf-tools` (MRC). Consequence: **Mac App Store permanently unavailable** (AGPL-incompatible) — accepted; distribution is a **notarised DMG**. **Repo private during development; user flips it public at/before release** — AGPL obligations trigger only on distribution, so private dev is compliant.
- **Build path (verified on this machine 2026-07-22):** **Xcode 26.6 is installed and functional** (`xcode-select -p` = `/Applications/Xcode.app/…`, `xcodebuild -version` = Xcode 26.6, macOS 26.5 SDK present). **Primary build = an Xcode project generated from a declarative XcodeGen `project.yml`, built via `xcodebuild`** — the standard macOS-app path, which makes the `.app` bundle, entitlements/hardened-runtime, code-signing, notarisation and DMG straightforward. `xcodegen` is not yet installed but `brew` is present → `brew install xcodegen` (an M0 setup step). **Fallback: Swift Package Manager (`swift build`) + a bundling script** (verified CLT-compatible) — kept as a documented alternative so the build has no single point of failure. `notarytool` is available (`xcrun notarytool`); notarisation needs the user's Apple Developer account + network at release.
- **Native C/C++ deps are statically linked** into the app binary (one Mach-O). Verified (evidence/native-lib-plumbing.md): libdeflate built for arm64, linked via a module map, round-tripped, code-signed with `--options runtime` and **zero special entitlements** (`codesign -v --strict` clean). Ghostscript is the exception — a **separate bundled executable** invoked via `Process` (not linked), signed as an embedded helper (see §11 for its bundling risk).

## 4. Architecture

Three layers; the two tools share most machinery.

```
PDF Toolbox (SwiftUI)
├─ Shell            NavigationSplitView sidebar: [Compress] [OCR] [Merge·soon] [Split·soon]
├─ SHARED (built once, used by both tools)
│   ├─ ToolQueue          drag-drop · file list · batch runner · per-file state machine · estimate/result display
│   ├─ PDFService         open/save · page inspection · ContentRouter (per doc/page: born-digital vs image-scan)
│   ├─ PDFWriter          our own PDF construction — (a) incremental-update append (OCR text layer, images untouched);
│   │                     (b) image-XObject page construction/splice (JBIG2/CCITT/MRC pages). Owns coordinate math.
│   ├─ VisionOCR          VNRecognizeTextRequest → text + normalised bounding boxes (Neural Engine)
│   └─ TextLayerEmbedder  Vision observations → invisible selectable text via PDFWriter(a)
├─ CompressEngine   routes per document: born-digital/mixed → Ghostscript; pure scan → native encoders + PDFWriter(b)
└─ OCREngine        ContentRouter → VisionOCR → TextLayerEmbedder
```

Why **PDFWriter** exists (fixes R1-M3/M4): Apple provides no in-place PDF-object edit API (verified, §9), and Ghostscript cannot import JBIG2/MRC images. So every output that isn't "GS re-distills the whole file" — JBIG2/CCITT scan pages, MRC pages, and the OCR invisible-text layer — requires us to write PDF bytes ourselves. `PDFWriter` is that single owner; `archive-pdf-tools` is the reference for its image-XObject/MRC assembly. It is carried as a scoped implementation risk (§11).

**Module contracts (each independently testable):**
- `ContentRouter.classify(doc) -> .bornDigital | .scan(.bilevel|.colour) | .mixed` — from PDFKit page inspection (extractable text coverage; image coverage). **`.bilevel` is content-based (R2-N5):** "visually near-two-tone", determined by image analysis (corpus-tuned) — **not raw bit-depth**. 8-bit greyscale scans that are visually bilevel still take the binarise→JBIG2 path (which is why Rung 2 begins with a leptonica binarise step); this is what earns the headline 15–40× on ordinary greyscale document scans.
- `CompressEngine.compress(url, preset, progress) async throws -> CompressResult`
- `OCREngine.ocr(url, options, progress) async throws -> OCRResult`
- `PDFWriter` — append-mode and assemble-mode; owns Vision-normalised→PDF-user-space coordinate mapping incl. page rotation & MediaBox. **Preservation contract (R2-N2):** assemble-mode (rebuilding scan pages) carries over document metadata and outlines/bookmarks; page-level annotations/links present on a rebuilt page are re-attached where feasible, otherwise recorded as dropped in the result summary — because the §5.4 open+render check cannot detect silently-dropped structure.
- `ToolQueue` is generic over a job so both tools reuse queue/batch/state/estimate UI; only the options panel + run action differ.

**Concurrency:** batch runs jobs concurrently, capped (default = performance-core count, tunable); each job cancellable; honest per-file + overall progress; heavy work off the main actor.

## 5. Compress tool

### 5.1 Engine — Strategy 1 (Ghostscript-core), staged ladder, content-routed
`CompressEngine` classifies each document and routes it:
- **Born-digital or mixed** → **tuned Ghostscript `pdfwrite`** (preserves vector text; subsets fonts; dedups; downsamples colour images to preset DPI; CCITT G4 for any bilevel images). This is **Rung 1** — a gold-standard compressor that ships first.
- **Pure scan** → **native scan pipeline** (the big wins): bilevel pages → leptonica binarise → jbig2enc (lossless JBIG2) or CCITT G4 → `PDFWriter` assembles (**Rung 2**); colour/grey scan → MRC (leptonica segmentation → JBIG2 mask + downsampled background/foreground, layers JPEG-encoded via ImageIO for v1) → `PDFWriter` assembles (**Rung 3**).

Per-page routing *inside* a mixed document (e.g. a born-digital report with a scanned appendix) is **v1.1**: v1 sends mixed docs whole to Ghostscript (safe; GS still downsamples/CCITTs images within), reserving the native JBIG2/MRC treatment for predominantly-scan documents — where the compression actually matters.

**Routing fallback (R2-N1):** any content class whose rung is not yet built or is gated out (JBIG2 pending viewer verification, or the MRC spike failing) routes to **Ghostscript (Rung 1)** — no document is ever left unhandled, and Rung 1 alone is always a valid, shippable engine.

| Rung | Path | Target | Gate |
|---|---|---|---|
| **1** | tuned GS (born-digital/mixed) | gold-standard general; ships in days | GS build+sign+invoke gate (§11) |
| **2** | jbig2enc/CCITT + PDFWriter (bilevel scans) | 15–40× (JBIG2) / 5–15× (CCITT) | **lossless JBIG2 only**; JBIG2 viewer support **verified before default**, else CCITT |
| **3** | MRC port + PDFWriter (colour scans) | beats stock GS on colour scans | segmentation **spike** on real scans first; ship without it if inadequate |

GS tuning baseline (evidence/engine-research-2.md): `/ebook` overridden — `/Bicubic` downsample to preset DPI, `AutoFilter*=false`, per-preset `QFactor`, `SubsetFonts/CompressFonts`, `DetectDuplicateImages`, `-dFastWebView`; **DCTDecode passthrough** (never re-encode already-JPEG-at-target-DPI images). Exact numbers finalised against a corpus (§5.5). *v1 native deps: Ghostscript + leptonica + jbig2enc + the MRC port. jpegli/libdeflate are deferred (v1.1) — GS handles born-digital encoding; MRC layers use ImageIO JPEG for v1.*

### 5.2 Presets (map to GS tuning; exact DPI/QFactor set in §5.5)
**Smallest** (aggressive) · **Balanced** (default) · **High quality** (light touch).

### 5.3 Per-file estimate
Before compressing, a **time-boxed, parse-only analysis** produces a per-file estimate: parse image XObjects (bytes, pixel dims → effective DPI, colour space), model post-preset recompressed size, sum. Shown as an estimate (`~X MB · ~Y% smaller`); the **real** figure replaces it after compression. **Parse-only, no encode; time-boxed per file** (coarse-estimate beyond a cap) so a 1000-page scan never stalls the UI; runs async. **Fallback (pinned criterion, R1-M7):** if median estimate error exceeds **±25 %** on the validation corpus, or analysis exceeds **500 ms/file**, switch that build to *typical ranges per preset* instead of per-file figures.

### 5.4 Behaviour & safety
- Output `<name>-compressed.pdf` **alongside the original**, optional batch output-folder override, **never overwrite**.
- **Atomicity (R1-M8):** write to a temp file, then atomic rename on success; a cancelled or failed job leaves **no partial output**.
- **Never emit a larger file:** compare output vs input bytes, keep the smaller; if not smaller, mark **"already optimised"**, keep the original.
- **Output validation (R1-M9):** before reporting success, re-open the output via PDFKit **and** assert page count == input **and** render-sample N pages (default 3, incl. first/last) without error — catches blank-page/JBIG2 corruption, not just "it opens".
- **Untrusted-PDF security (R1-M2, mandatory):** input PDFs are untrusted and Ghostscript has a CVE history (e.g. CVE-2023-36664). Containment mechanism, pinned: the GS `Process` runs under a **macOS seatbelt sandbox profile** (via `sandbox-exec`/an XPC-isolated helper) that **denies network** and **restricts the filesystem to exactly the input file, the output directory, and GS's own resource bundle**; plus `-dSAFER` (assert it — default since GS 9.50), and per-job **memory + wall-clock caps**. Residual risk: a GS sandbox-escape CVE could still act within those FS/no-network limits — recorded (§11.4); mitigated, not eliminated.
- **CMYK:** `ConvertCMYKImagesToRGB` on screen presets; preserve on High quality (avoid colour shift / broken print intent). Finalised in §5.5.
- **Encrypted/corrupt (shared behaviour — applies to both Compress and OCR) (R2-N3):** detect up front; password-protected → per-file prompt or skip-with-error; corrupt → that one file fails inline, batch continues.

### 5.5 Corpus validation (privacy-bound)
Presets, CMYK policy, JBIG2 viewer support and estimate accuracy are tuned/validated against a **local, machine-local test corpus of representative PDF *types*** (born-digital, colour scan, B/W scan, mixed, encrypted, corrupt, very-large). **The corpus is never committed; committed test fixtures are synthetic/anonymised only. No personal document paths, names, or contents appear anywhere in this repo.**

## 6. OCR tool

- **Detect** (via `ContentRouter`): OCR only **image-only pages** with no extractable text. A page/doc that already has extractable text → **"already searchable — nothing to do."** **Mixed pages are skipped in v1** (they already carry text; per-region OCR of their image areas is v1.1) (R1-M11).
- **Recognise:** render each image-only page to a raster at **300 DPI (default, corpus-tunable)** (R1-M10) and run Vision `VNRecognizeTextRequest` → text + normalised boxes. **Accuracy** `.accurate` default + fast/accurate toggle. **Languages** auto-detect + optional override.
- **Embed (mechanism pinned, R1-M4):** `TextLayerEmbedder` adds an **invisible, selectable text layer via `PDFWriter` incremental update** — appended objects only, so the **original page bytes/images are untouched** (hence "appearance unchanged" is literally true, and is still validated per §5.4). `PDFWriter` owns the coordinate contract: **Vision normalised coordinates → PDF user space, accounting for page rotation and MediaBox origin**, with glyph size fitted to each observation's bounding box.
- **Output:** `<name>-ocr.pdf` alongside, never overwrite. OCR **adds a text layer only** — no image alteration, no compression (distinct from Compress; a combined pass is v2).

## 7. UI

- **Compress UI:** rebuild Claude Design's `Toolbox.dc.html` **in SwiftUI, matching its visual output** (read it + `support.js` in full; match appearance, not prototype structure). Apple design language per repo `DESIGN.md`. Both **light and dark** mode; native controls, SF Symbols, system materials/vibrancy, resizable window, collapsible sidebar.
- **Deviations from the mockup (R1-M5) — the SwiftUI build follows these, not the mockup, where they conflict:**
  1. **Sidebar = exactly §4's set (R2-N4):** four entries only — Compress + **OCR** live (the mockup predates the OCR decision and lacks it), Merge + Split as dimmed "Soon". The mockup's other entries (PDF-to-Word, Images-to-PDF, Protect) are **omitted entirely** — no other sidebar entries in v1.
  2. **"Saved this month · 1.24 GB" stats widget: cut from v1** — it needs cross-session storage + reset semantics (out of scope, §2). Reconsidered for v2.
  3. **Per-file % / MB figures** on preset cards are the **real §5.3 estimates**, not fabricated.
- **OCR UI:** derived from the same design system + Claude Design's components — identical shell/queue/batch/state machine, an **OCR options panel** (language, accuracy) replacing preset cards, an "OCR N PDFs" action. No size estimate (OCR adds a layer); may show "N pages to OCR". No separate design round (user-confirmed).

## 8. States (both tools, shared machine)

Empty (drop zone + Choose Files, + drag-hover) → Ready (files + options + estimate + action) → Working (per-file + overall progress, cancellable) → Done (per-file result + summary + Reveal in Finder). Plus per-file **error** and **already-optimised / already-searchable**. **Progress is honest** — page-based where possible; no fabricated percentages.

## 9. Decisions & rejected alternatives (whys)

- **Engine = Ghostscript-core (born-digital) + native scan pipeline, not pure-Apple.** GS is the gold-standard text-preserving optimiser and drop-in low-risk for born-digital. *Rejected pure-Apple:* Apple's PDF write API is only two shapes — PDFKit optimise (one fixed level → **can't deliver 3 presets on born-digital**) and rasterise (tunable but flattens text); no in-place image API; caps on bilevel scans (no JBIG2/CCITT). Verified against SDK headers (§10). *Rejected PDFium-permissive (BSD):* viable/more-native, but once AGPL is accepted for MRC it buys nothing GS doesn't and forces from-scratch MRC.
- **AGPL accepted, open-source at release.** Unlocks GS (free) and lets **MRC be a port** of `archive-pdf-tools` rather than from-scratch — collapsing the project's biggest risk. Costs (MAS foreclosed, un-native engine) accepted: "best" outranks "native", distribution is DMG.
- **MRC staged to Rung 3, preceded by a spike.** Building MRC first yields a *worse* MRC — segmentation quality is empirical and needs the corpus + measurement harness + router + `PDFWriter` (which are the baseline). Confirmed by the Fable-5 advisor consult.
- **Two tools in v1.** OCR validates the extensible shell, is fully native/Vision (balances GS's un-nativeness), reuses Compress's queue/router/`PDFWriter`.
- **UX:** batch queue; 3 reductive presets; output alongside + never-overwrite + never-enlarge; per-file estimate via quick analysis (all user-confirmed).

## 10. Verification evidence (this session)

- **Engine/licences** — engine-research.md/-2.md. Licences confirmed first-hand: jpegli/libjxl BSD-3, leptonica BSD-2 (both fetched), jbig2enc Apache-2.0, libdeflate MIT, openjpeg BSD-2; Ghostscript AGPL; archive-pdf-tools AGPL.
- **Apple PDF API limits** — grepped installed SDK headers: `saveImagesAsJPEG`/`optimizeImagesForScreen` are booleans; `compressionQuality` only on the image-init (rasterise) path. Confirms no tunable text-preserving native path and no in-place edit API.
- **Native-lib plumbing** — native-lib-plumbing.md: real arm64 build + static link + round-trip + clean codesign (low risk).
- **Toolchain — verified live (2026-07-22, updated after the user installed Xcode):** **Xcode 26.6 functional** (`xcodebuild -version` OK, macOS 26.5 SDK); `swift`/SPM works (Swift 6.3.3, arm64); `notarytool` available; `xcodegen` not yet installed but `brew` present to install it. (Round-1 reviewed an earlier CLT-only state where xcodebuild was absent; the machine has since gained Xcode — both the Xcode and SPM paths are now viable, Xcode primary.)

## 11. Risks & fallbacks

1. **MRC segmentation quality** (top) — mitigated by porting a proven reference + an early spike; fallback: ship without Rung 3 (baseline excellent).
2. **PDFWriter correctness** (R1-M3) — hand-written PDF assembly (JBIG2/MRC pages, incremental-update text) is fiddly; mitigated by following `archive-pdf-tools` + the §5.4 output-validation gate on every file.
3. **JBIG2 portability** — viewer support unverified on recipients; verify empirically before defaulting; **CCITT G4 universal fallback**; lossless JBIG2 only (lossy corrupts digits). Verification matrix (R1-M12): test JBIG2 rendering on the macOS versions reachable in dev (this machine is macOS 26 only; floor is 14) + Preview + one third-party viewer; until verified across the support range, **CCITT is the default and JBIG2 is opt-in**.
4. **GS security** (R1-M2) — seatbelt sandbox (no network, FS-scoped) + `-dSAFER` + caps + output re-validation; residual: an escape-within-sandbox CVE — accepted, monitored, GS kept updated.
5. **GS build & bundle** (R1-M6) — `gs` is not installed; it must be **built from source for arm64, bundled with its Resource tree + dylibs, each signed**, and pass notarisation — the plumbing evidence calls this a bigger risk than the four probed libs (only libdeflate was probed). **Gate (M1):** build + sign + invoke the bundled GS helper end-to-end on a real PDF *before* any engine tuning; if bundling proves intractable, fall back to requiring a user-installed GS (documented) — do not silently ship a broken engine.
6. **Estimator accuracy/speed** — §5.3 criterion + typical-ranges fallback.
7. **Notarisation** — needs the user's Apple Developer account + network; `notarytool` present; release-step dependency, not a dev blocker.
8. **Build tooling** — Xcode project (XcodeGen `project.yml` → `xcodebuild`) proven in M0 before feature work; `brew install xcodegen` is an M0 setup step; SPM + bundle-script kept as a validated fallback.
9. **Memory on 1000-page scans** — stream page-by-page, cap concurrency, release buffers; validate on a large scan.

## 12. Milestones (build order)

- **M0** Xcode project (XcodeGen `project.yml`) builds the SwiftUI app end-to-end via `xcodebuild` (→ signed `.app` → launches); `brew install xcodegen` as setup; SPM+bundle fallback validated. + empty shell (sidebar, two tool stubs) + `ToolQueue`/`PDFService`/`ContentRouter` + `PDFWriter` foundation + synthetic-corpus + measurement harness.
- **M1** Compress Rung 1 (tuned GS, seatbelt sandbox, `-dSAFER`, never-enlarge, output-validation) **behind the GS build+sign+invoke gate** + full Compress UI (per §7) + estimate pass.
- **M2** OCR tool (Vision detect → recognise → `PDFWriter` incremental-update embed) + derived OCR UI. (First real `PDFWriter` consumer.)
- **M3** Compress Rung 2 (jbig2enc + CCITT + `PDFWriter` assembly, JBIG2 verification gate).
- **M4** MRC spike → Rung 3 (port) if the spike passes.
- **M5** Polish (animation, empty/error states, keyboard/menus, dark mode) + notarised DMG.

## 13. Definition of done (v1)

**v1-done = Rungs 1–2 + OCR solid and shippable.** Rung 3 (MRC) ships **iff** the segmentation spike (M4) passes; if not, it defers to v1.1 **without blocking v1** (R1-M13). Concretely: both tools work on the synthetic + local corpus (born-digital, colour scan, B/W scan, mixed, encrypted, corrupt, 1000-page); **every output re-opens in Preview + one other viewer, page count preserved, sampled pages render**; no output larger than input; batch cancellable with honest progress and atomic outputs; UI matches Claude Design fidelity in light + dark; the app builds/tests/signs from the CLI (`xcodebuild`, SPM fallback) and packages into a notarisable DMG; `.claude/GATES.md` (authored with the first code) green.

---

## Round log
- **R1** (Fable 5, full read): NO-SHIP — 1 critical (C1 toolchain evidence), 5 major (M2 GS sandbox, M3 PDF-assembly, M4 OCR mechanism, M5 UI deviations, M6 GS-bundle risk), 7 minor. Findings persisted at `.git/lcw/20260722-pdf-toolbox-v1/spec-review-r1.md`. Lesson-candidates LC-A/B/C recorded for retro.
- **R2** (revision): all C1/M2–M6 + minors 7–13 fixed (PDFWriter module; GS seatbelt sandbox; OCR incremental-update + coordinate contract; §7 deviation list; GS-bundle risk + M1 gate; the seven minors). **Gate verdict: SHIP** — all R1 critical/major genuinely resolved; 5 new minors (N1–N5). Findings: spec-review-r2.md; lesson-candidates LC-D/E → retro.
- **R2 post-SHIP fixes:** N1 rung-absent routing → GS; N2 PDFWriter preservation contract; N3 shared encrypted/corrupt handling; N4 pinned 4-entry sidebar; N5 content-based `.bilevel`. **Toolchain update:** user installed Xcode 26.6 mid-review (verified functional) → build path switched from SPM-primary to **Xcode/XcodeGen+xcodebuild primary** (SPM fallback); §3/§10/§11.8/§12/§13 updated. This is a factual toolchain improvement (more-standard path, lower bundling/notarisation risk), no product/architecture/security change → certified for human approval.
