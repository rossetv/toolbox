# Brainstorm Sanity Review — PDF Toolbox (Compress), one pass

No FATAL finding (the idea can ship something good). But the two most valuable
issues concern the engine *choice* and a UX-vs-engine gap the ladder hides.

## Findings (most severe first)

### F1 — Engine choice — MAJOR — AGPL is already the app's licence, which puts Ghostscript back on the table and undercuts the case for building native Rungs 1–2
The engine is stated as "permissive **+AGPL(at-release)**", and Rung 3 **PORTS** the
Internet Archive archive-pdf-tools, which is **AGPL** — porting AGPL code is only
legal if the app itself ships AGPL. So **the app licence is already decided: AGPL at
release.** That is the very licence that governs **Ghostscript.**
- Path B was invented to dodge a wall that no longer exists: research-1's rationale is
  "AGPL forbids bundling GS in a **closed-source** distributed app." The app isn't
  closed-source. **Bundling GS is fully legal here.**
- On **born-digital PDFs** — Rungs 1–2's own target — GS *beats* the native pipeline:
  it subsets fonts, dedupes objects and rewrites structure, which native won't
  (research-1 quality-gap §). Native only pulls *ahead* of GS at Rung 3 (MRC on colour
  scans).
- **The sharp question the spec must answer:** why build native Rungs 1–2 at all,
  rather than bundle **tuned Ghostscript (+ jbig2enc)** for Rungs 1–2 and spend the
  scarce native effort only on the **MRC port** that genuinely beats GS? Path B's
  justification was closed-source-driven; that premise is gone. Record why
  native-over-GS still wins (e.g. "no subprocess", "native Apple-Silicon identity",
  bundle size) — or switch to the far cheaper GS-based Rungs 1–2.
- **Confirm the strategic cost the AGPL choice already locks in:** AGPL is
  incompatible with the Mac App Store (research-1 §3e). Porting AGPL archive-pdf-tools
  therefore **forecloses a future MAS build permanently.** The human should sign off on
  giving up the App Store, not back into it.

### F2 — Rung 1 / UX — MAJOR — the 3 DPI presets can't drive born-digital output, and mixed pages are the routing hazard
Read plainly, Rung 1 ("pure-Apple baseline… zero from-scratch algorithms") is
research-2's **Path C** and is feasible with zero libs: router → born-digital pages
get PDFKit-optimise (fixed), scan/image pages get rasterised (Metal/vImage + ImageIO,
encoder behind the swappable protocol) + a Vision OCR re-layer. The gaps are not
feasibility — they are two the spec must pin:
- **The 3 presets (~96/150/225 DPI) cannot produce different born-digital results.**
  PDFKit `write(withOptions:)` optimise is a **single fixed target** ("HiDPI screen
  resolution") with no DPI/quality knob (research-1 §2a). On a born-digital PDF,
  Smallest/Balanced/High all yield the *same* file. The UX promises tunability the
  Rung-1 engine can't deliver off the rasterise path. Decide: presets vary only the
  scan/rasterise path (and born-digital ignores them — then say so in the UI), or
  born-digital needs tunable recompression = the substrate below.
- **Mixed pages (text + a large image) are the routing hazard.** Rasterise → lose the
  text; optimise → barely shrink the image. This per-page call is Path C's main
  failure mode (research-2 Path C §). Spec the decision rule (e.g. rasterise only when
  image-area ⁄ text ratio clears a threshold, and always Vision-re-OCR when you do).
- **Substrate is contingent, and belongs at Rung 2 — not decision #0.** *If* the human
  wants tunable, text-preserving recompression of born-digital images (and Rung 2's
  libdeflate stream re-packing already implies object-level access), Apple offers **no
  in-place edit API** (`CGPDFDocument` read-only, `CGPDFContext` create-only). That
  needs **PDFium** (BSD-style, exposes `FPDFImageObj_SetBitmap` to replace image
  objects in place — verified this session) or hand-rolled PDF serialisation. This
  lands where the brainstorm *already* scoped native-lib plumbing (Rung 2). *If* Path
  C's fixed optimise is acceptable for born-digital, Rung 1 ships as-is with no
  substrate.

### F3 — Output validity — MAJOR — no decided "did we corrupt it?" gate
"Never emit larger" is decided (good). But rasterise/optimise/MRC can silently produce
a **valid-size but broken** PDF (misaligned SMask → black boxes, dropped OCR layer,
viewer-specific blank pages). "Validate in Acrobat/Chrome" is in the research but has
no mechanism — you can't bundle Acrobat. Spec a concrete post-compress check: re-open
with PDFKit, assert page count unchanged, render-sample N pages, plus the JBIG2
viewer-portability check already flagged. A compressor that silently corrupts is worse
than useless against a "preserve quality" bar.

### F4 — Untrusted-PDF security — MAJOR — parsing hostile input with bundled C libs, no decided boundary
An open-source DMG opening arbitrary PDFs is a parser-attack surface. PDF/JBIG2
decoders are a classic RCE vector (CVE-2021-30860 FORCEDENTRY was a JBIG2 **decode**
bug in CoreGraphics — you bundle jbig2enc for *encode*, but leptonica/ImageIO/any PDF
substrate still *decode* untrusted input). Spec must decide: resource limits
(decompression bombs), per-file crash isolation (XPC/subprocess so one malformed file
can't kill the app or corrupt a batch sibling), and graceful per-file error surfacing.

### F5 — Memory / concurrency on huge scans — MAJOR — no budget decided
A 1000-page colour scan rasterised or MRC-segmented at high DPI is gigabytes; a batch
queue processing N files × per-page rasters concurrently is an OOM waiting to happen
(and the Path C rasterise reading of Rung 1 *reinforces* this — every scan page becomes
a full bitmap). Pin: batch concurrency limit, per-page streaming (never hold the whole
doc as bitmaps), a peak-memory bound. "Drop many PDFs" makes this reachable by a normal
user, not an edge case.

### F6 — UI contradicts the "no pre-estimate" decision — MAJOR (cheap fix, must pin)
The mockup's **ready state shows a per-file pre-compression estimate**:
`Toolbox.dc.html` lines 197–209 render `→ {{ file.newText }}` (predicted compressed
size) and `{{ file.pctText }}` (−%) *before* any compression, computed from a fake
`eff()` model (`renderVals`). This directly contradicts the decided "No pre-compression
size estimate (only real result shown)." Same for the preset cards' computed
`smallestEstText`/etc. Drop the ready-state estimate from the build, or revisit the
decision. Also: the sidebar **"Saved this month · 1.24 GB"** (lines 80–84) is an
undecided **persistent usage-stats feature** (cross-session storage, reset, privacy for
an OSS app) — cut it or spec it.

### F7 — Spec gaps to pin (each a decided-behaviour hole) — MAJOR as a set
- **Encrypted/password-protected PDFs** (statements, contracts). PDFKit exposes
  `isEncrypted`/`isLocked`. Decide: skip-with-error vs prompt-for-password.
- **Corrupt / non-PDF-with-.pdf-extension**: per-file error path (ties to F4).
- **Cancellation atomicity**: mid-file cancel leaves no half-written output —
  temp-file-then-atomic-rename, which also enforces "never overwrite".
- **CMYK / colour-space policy**: preserve CMYK (JPEG APP14 minefield) vs convert to
  RGB (colour shift, breaks print intent). Decide + warn — load-bearing under a
  "preserve quality" bar for print users.
- **Existing OCR-layer detection**: many scans already carry a text layer; re-OCR
  (Vision) is wasteful and can *degrade* searchability by overwriting good text.
  Detect-and-skip before adding a Vision layer.
- **Honest progress without a pre-estimate**: use pages-processed / total-pages; the
  mockup's per-file bar is driven off a wall-clock timer (`compress()` setInterval),
  not real work — real impl must key off actual progress.

## Over-engineering check (smell test run)
- **Swappable-encoder protocol — JUSTIFIED, not a smell.** It has a real Rung-1 caller
  (encodes the rasterised page image via ImageIO) and a known Rung-2 upgrade
  (swap in jpegli). Keep it.
- **The staged ladder — good de-risking, NOT over-engineering** — provided "v1 done" is
  pinned at the earliest shippable rung, not silently at Rung 3 (see S2).
- **"Toolbox" shell with 6 "Soon" tools — NOT a real smell** (static disabled rows,
  cheap). But it publicly promises Merge/Split/PDF-to-Word/Protect/Images-to-PDF at
  launch — a product commitment to make consciously, not by mockup inheritance.

## Six-month costs
- **Owning bundled C libs (leptonica, jbig2enc, jpegli, libdeflate, + any PDF substrate)
  = a CVE-patch + arm64-rebuild + re-notarise treadmill**, forever, in public.
  leptonica/jbig2 have CVE history. Weigh against F1's "bundle one GS binary" — which,
  now AGPL is accepted, is legal.
- **MRC is a PORT of a mature reference (archive-pdf-tools), which de-risks vs
  from-scratch** — but you still own the Swift port, the segmentation tuning (every
  "muddy text / halo" report), and AGPL compliance. Real, just smaller than "invent it".
- **JBIG2 portability** may force the CCITT-G4 fallback (viewer support unverified).
  Designing for both from day one is correct and already decided — keep it.
- **AGPL forecloses the Mac App Store permanently** (see F1). A strategic door closed.

## Suggestions (human decides; trade-off in-line)
- **S1 — Ship Rungs 1–2 on tuned Ghostscript + jbig2enc; reserve native effort for the
  MRC port.** Now AGPL is the decided licence, GS is legal *and* beats the native
  pipeline on born-digital files. Benefit: GS-class result far faster, sidesteps the
  preset/substrate gap (F2) entirely, native code only where it wins (MRC). Trade-off:
  20–40 MB bundle + a subprocess (fine outside MAS; MAS already foreclosed by AGPL).
- **S2 — Define "v1 = ships at Rung 2 (JBIG2/jpegli or GS+jbig2enc); MRC is v1.1."**
  Benefit: a shippable, GS-parity-or-better product months sooner; MRC's segmentation
  risk off the v1 critical path. Trade-off: colour-scan superiority waits for v1.1.
- **S3 — If you keep the native path and want tunable born-digital recompression, adopt
  PDFium (BSD) as the Rung-2 substrate.** Benefit: the in-place image-replace API Apple
  lacks (F2), permissive, battle-tested in Chrome. Trade-off: a large C++ dep to
  build/sign/notarise.
- **S4 — Finder Quick Action / Share extension / right-click "Compress PDF".** Benefit:
  the most-requested macOS integration; users ask within a week. Trade-off: extension
  plumbing + the sandbox/XPC story you need for F4 anyway.
- **S5 — Optional "target size" mode ("get under 10 MB for email").** Benefit: the #1
  real user goal. Trade-off: needs trial encodes and sits in tension with "no
  pre-estimate" — a deliberate exception.
- **S6 — Before/after single-page preview on the done screen.** Benefit: builds trust in
  a "preserve quality" product; cheap (render one page each). Trade-off: minor UI.

## Lesson-candidates (candidates only — not findings, no severity)
- **LC1 — Inherited-rationale drift**: Path B carried a justification (avoid AGPL,
  closed-source) from research done under a constraint the final design *reversed*
  (open-source, and explicitly AGPL). Standing check: when a headline decision cites a
  rationale, verify the rationale's premise still holds under the *final* decision set.
- **LC2 — Read the evolved design, not the research it grew from**: the ladder's Rung 1
  had drifted from research Path B to Path C; reviewing it against the wrong path
  produces a wrong "infeasible" verdict. Check each staged rung against what it *now*
  says, not the doc it was distilled from.
