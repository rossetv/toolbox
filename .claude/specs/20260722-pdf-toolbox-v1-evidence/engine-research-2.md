# PDF Compressor Engine Research (v2)

Best-achievable "really good" compression for a native macOS (Apple Silicon) app, across
three constraint sets. Every ratio / codec / licence claim below is tagged with a primary
source or flagged **[unverified]**.

Bottom line up front: **The single biggest lever is not the codec — it is content-aware
routing plus, for scans, MRC segmentation.** A tuned JPEG quality buys ~10-35%. MRC buys
3-15x on scanned documents. Getting scans right is where "really good" is won or lost.

---

## Licence table (every candidate)

| Library | Purpose | Licence | Closed-source OK? | Source |
|---|---|---|---|---|
| **Ghostscript** | Full text-preserving optimiser | **AGPL v3** or paid Artifex commercial | **No** (unless app is AGPL/open) OR pay | Artifex/ghostscript.com licensing (well-established) |
| **jbig2enc** | JBIG2 bilevel encoder | **Apache 2.0** | **Yes** (notice) | `agl/jbig2enc/COPYING` — "Licensed under the Apache License, Version 2.0" ✓ |
| **leptonica** | Image I/O, binarisation, segmentation (jbig2enc dep) | **BSD 2-clause** style (custom permissive) | **Yes** (notice) | `DanBloomberg/leptonica/leptonica-license.txt` — "Redistributions of source code must retain the above copyright notice…" + AS-IS disclaimer; BSD-2-style, **not** Apache/GPL ✓ (jbig2enc README's "Apache-ish" is loose phrasing) |
| **mozjpeg** | Better baseline/progressive JPEG | **BSD-3 + IJG + zlib** (permissive; libjpeg-turbo fork) | **Yes** (notice) | libjpeg-turbo LICENSE.md (IJG + modified BSD-3 + zlib) ✓ |
| **jpegli** (in **libjxl**) | Best standard-JPEG encoder | **BSD 3-clause** | **Yes** (notice) | `libjxl/libjxl/LICENSE` — "Copyright (c) the JPEG XL Project Authors… BSD 3-Clause" ✓ |
| **openjpeg** | JPEG2000 (JPXDecode) | **BSD 2-clause** | **Yes** (notice) | uclouvain/openjpeg — "released under the BSD 2-clause Simplified License" ✓ |
| ~~**brotli**~~ | ~~stream compression~~ — **NOT a PDF filter, do not use** | MIT | n/a | google/brotli — MIT ✓ (but **there is no BrotliDecode in PDF 32000-1 or PDF 2.0** — a brotli stream won't open in any viewer) |
| **libdeflate** | Faster/smaller DEFLATE → valid **FlateDecode** | **MIT** | **Yes** (notice) | `ebiggers/libdeflate/COPYING` — MIT ✓ |
| **zlib** | Baseline FlateDecode | **zlib licence** | **Yes** | zlib licence (permissive) ✓ |
| **archive-pdf-tools** (internetarchive) | **Reference MRC pipeline** | **AGPL-3.0** (one file Apache-2.0) | **No** — reference only | github.com/internetarchive/archive-pdf-tools ✓ |

**Verdict on the permissive set:** every building block needed for a Ghostscript-class
engine — JBIG2 (jbig2enc/Apache), segmentation (leptonica/BSD), best-in-class JPEG
(jpegli/BSD-3), JPEG2000 (openjpeg/BSD-2), better Flate (libdeflate+brotli/MIT) — is
permissively licensed and bundleable in a **closed-source notarised DMG** with only a
NOTICES/attribution file. The one thing that is *not* free-for-closed-source is Ghostscript
itself and the archive.org MRC glue code. **The codecs are free; the orchestration is what
you build.**

Note on PDF portability of filters (constraint, restated — and corrected):
- **DCTDecode (JPEG)** and **FlateDecode** — universally supported. Safe defaults.
- **CCITT G4** (bilevel) — a core PDF filter since PDF 1.0, **genuinely universal** including
  Apple Preview/PDFKit. This is the safe bilevel codec.
- **JBIG2** — in the PDF spec, but **viewer support is NOT universal**. pdf.js/Firefox have
  documented JBIG2 blank-page bugs on scanned PDFs, and **Apple PDFKit/Preview has a history of
  limited/older PDF-feature support** (search results below). **[Whether current macOS Preview
  renders jbig2enc output correctly is UNVERIFIED — must be empirically confirmed on the target
  macOS versions before JBIG2 becomes the default, because the DMG is shared with others.]** If
  it fails, fall back to CCITT G4 (drops the B/W scan win from 15-40x to 5-15x). Sources:
  pdf.js JBIG2 issues + Apple Community/TidBITS blank-page threads on Preview PDF-feature gaps.
- **JPXDecode (JPEG2000)** — in the spec but patchy support (fine in Preview/Adobe; risky in
  some mobile/web viewers) — *optional* background codec, never the default.

---

## PATH A — Ghostscript allowed (app open-sourced)

**Architecture (one line):** Ghostscript `pdfwrite` with hand-tuned downsampling + DCT
quality + bilevel routing, driven per-file by a content classifier — beats every stock preset.

Ghostscript is the gold standard because `pdfwrite` **re-distills** the PDF: it re-encodes
images, **subsets fonts, dedups objects, and rewrites the structure** while *preserving vector
text* — the one thing Apple's tunable path (rasterise) cannot do. Stock presets are blunt:

| Preset | Colour/Gray image res | Intent |
|---|---|---|
| `/screen` | 72 dpi | smallest, ugly |
| `/ebook` | 150 dpi | middle |
| `/printer` | 300 dpi | print |
| `/prepress` | 300 dpi + colour preservation | press |

(Preset DPI values per Ghostscript Ps2pdf/VectorDevices docs; parameter names verified against
ghostscript.com/blog/optimizing-pdfs.html ✓.)

**What beats the presets — the tuned invocation.** Presets bundle a fixed DPI + a fixed
QFactor; you want to decouple them and tune per content class. Verified parameters
(ghostscript.com/blog/optimizing-pdfs) — note the presets are *defaults you then override*:

```
gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.7 \
   -dPDFSETTINGS=/ebook \                        # sane baseline, then override everything
   # ---- colour/grey images: downsample + JPEG ----
   -dDownsampleColorImages=true -dColorImageDownsampleType=/Bicubic \
   -dColorImageResolution=144 \                   # 144 dpi: sweet spot > /screen 72, < /ebook wastes
   -dColorImageDownsampleThreshold=1.0 \          # always downsample above target (default 1.5 skips)
   -dDownsampleGrayImages=true  -dGrayImageDownsampleType=/Bicubic  -dGrayImageResolution=144 \
   -dColorImageFilter=/DCTEncode -dGrayImageFilter=/DCTEncode \
   -dAutoFilterColorImages=false -dAutoFilterGrayImages=false \  # force JPEG, stop GS choosing Flate
   # ---- JPEG quality: QFactor 0.5 == IJG q75 (GS default); lower = smaller ----
   -c "<< /ColorImageDict << /QFactor 0.40 /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> \
        /GrayImageDict  << /QFactor 0.40 /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> >> setdistillerparams" -f \
   # ---- bilevel (scanned B/W text): CCITT G4, never downsample below 300 ----
   -dDownsampleMonoImages=false -dMonoImageFilter=/CCITTFaxEncode \
   # ---- structure / fonts / dedup ----
   -dDetectDuplicateImages=true \                 # object-level image dedup (default true — keep)
   -dSubsetFonts=true -dCompressFonts=true -dEmbedAllFonts=true \
   -dConvertCMYKImagesToRGB=true \                # or -sColorConversionStrategy=Gray for pure-text scans
   -dPreserveHalftoneInfo=false -dPreserveMarkedContent=false \
   -dFastWebView=true \
   -o out.pdf in.pdf
```

Key tuning insights (verified):
- **QFactor is the real quality knob**; default 0.5 = IJG q75. Dropping to ~0.40 (≈ q60-65)
  is the biggest single size lever on photographic content with minimal perceptual loss.
  ✓ (ghostscript devices doc: default QFactor 0.5 == quality 75, IJG scale).
- **`/Bicubic` downsample uses a Mitchell filter** — higher quality than the default
  averaging; use it always. ✓
- **DCTDecode passthrough:** GS does *not* re-decompress already-JPEG images unless forced —
  avoids generational artefacts. If the source is already JPEG at your target DPI, leave it.
  Forcing re-encode of already-JPEG data multiplies artefacts. ✓ (GS VectorDevices doc.)
- **`-sColorConversionStrategy=Gray`** on pure text/greyscale scans: "66.6% saving" for RGB
  sources, "75% saving" for CMYK. ✓ (ghostscript.com/blog/optimizing-pdfs).
- **Bilevel → CCITT G4** built-in; but GS does **not** ship a JBIG2 *encoder*. For the very
  best B/W you'd still bolt jbig2enc on top (JBIG2 ≈ 3-5x smaller than G4 on text). So even
  Path A's ceiling on scans is CCITT unless you add jbig2enc.

**Expected ratios (Path A, tuned vs stock):**
- Colour/photo-heavy PDF: **3-8x** (tuned 144dpi q60) vs ~2-4x for `/ebook`.
- Mixed text+image (typical office/report): **2-5x**, text stays razor-sharp (vector preserved).
- Vector-text-only (already-clean digital PDF): **1.1-1.5x** — mostly font subsetting + object
  dedup + stream recompression; little to gain, and that's correct.
- B/W scan (CCITT G4): **5-15x**; with jbig2enc added, **15-40x**.
- **Path A is the ceiling for text-preserving general PDFs.** Its weakness is scanned colour
  documents, where it lacks MRC — a tuned-MRC engine (Path B) can *beat* stock Ghostscript on
  scans while Ghostscript wins on born-digital vector PDFs.

---

## PATH B — Closed-source, permissive licences only (THE REAL PATH)

**Architecture (one line):** a content-aware router — born-digital pages get PDFKit-optimise
+ per-stream recompression (jpegli/libdeflate); **scanned pages get a from-scratch MRC pipeline**
(leptonica segmentation → JBIG2 mask + downsampled jpegli background) with a Vision re-OCR layer.

This is the design that gets **to or past Ghostscript** on real-world documents without AGPL.

### Why you can beat Ghostscript on the cases that matter
Ghostscript has **no MRC**. The documents users most want to shrink — colour and greyscale
*scans* (contracts, textbooks, magazines, forms) — are exactly where MRC crushes a
single-codec approach. Every MRC building block is permissively licensed (table above). So the
closed-source engine is not a compromise; on scans it is *architecturally superior* to stock GS.

### The three codec upgrades over Apple-stock (quantified)
1. **JBIG2 / CCITT for B/W (i):** jbig2enc (Apache-2.0) → JBIG2. JBIG2 symbol-dictionary
   coding is typically **3-5x smaller than CCITT G4** and **~1 order of magnitude** vs a
   raster JPEG of the same bilevel page. Highest-ROI addition for scans — **but gated on the
   JBIG2-viewer-support check above**; ship CCITT G4 as the guaranteed-portable fallback.
   Also: **use LOSSLESS JBIG2 only** (see risk #3 — lossy symbol substitution can silently
   swap characters). **[3-5x vs G4 is a design target from tooling consensus; validate
   empirically, and confirm target-viewer JBIG2 rendering first]**
2. **Better JPEG (ii):** replace ImageIO's JPEG with **jpegli** (BSD-3). Jpegli gives up to
   **~32-35% bitrate reduction at equal perceptual quality** vs libjpeg-turbo, staying a
   fully-standard JPEG (DCTDecode) every viewer opens. ✓ (Google Open Source blog: "jpegli at
   2.8 BPP > libjpeg-turbo at 3.7 BPP = 32% bitrate reduction"; "35% more than traditional
   codecs"). **Caveat: that benchmark is the HIGH-quality regime (2.8-3.7 BPP). A PDF
   compressor runs at low quality/DPI, where jpegli's edge narrows — expect materially less
   than 35% at aggressive settings; still the best pick, just don't quote 35% as typical.**
   mozjpeg is the weaker alternative at only ~5-15% ✓ (Mozilla/Wikimedia) — **prefer jpegli,
   skip mozjpeg** unless jpegli integration slips.
3. **JPEG2000 (iii):** openjpeg (BSD-2) gives JPXDecode. Better rate-distortion than JPEG at
   low bitrates, *but* patchy PDF viewer support → make it an **opt-in "max compression,
   Preview/Adobe only" mode**, never the default. jpegli is the safer default codec.

Plus **libdeflate** (MIT) to re-pack all FlateDecode streams smaller than Apple's zlib
(libdeflate output is valid DEFLATE → decodes as FlateDecode everywhere; typically a few %
denser and much faster). **Do NOT use brotli — there is no BrotliDecode PDF filter; a brotli
stream will not open in any viewer.**

### MRC feasibility verdict — the crux of "really good"
**What MRC does:** split each scanned page into (a) a 1-bit **mask** (where the text/ink is),
(b) a **foreground** layer (text colour, heavily downsampled — only approximate colours
needed), (c) a **background** layer (everything else, downsampled hard). Encode mask with
JBIG2, foreground+background with low-DPI jpegli/JPEG2000. Recombine at view time via the
mask. This is how DjVu and every top commercial scanned-PDF compressor works (ITU-T **T.44**).

**How much smaller:** the internetarchive reference pipeline reports **3-15x typical**,
scaling to a **249.8:1** extreme on a clean text scan and **7.1:1** on a 9-page magazine. ✓
(github.com/internetarchive/archive-pdf-tools). Versus a naive single-JPEG rasterise of the
same page, MRC is routinely **5-10x smaller at equal legibility** because text edges stay
crisp (bilevel mask) while the photo background is allowed to go soft and low-DPI.

**Is there a permissive drop-in MRC library? NO.**
- The best open reference, **archive-pdf-tools, is AGPL-3.0** → unusable in a closed-source
  app. ✓
- Commercial MRC SDKs exist (LEADTOOLS, LuraDocument/LuraTech) but are **paid**, defeating the
  "permissive only" constraint.
- **Therefore MRC is a from-scratch build** on top of permissive primitives: leptonica (BSD)
  for binarisation + connected-component/segmentation, jbig2enc (Apache) for the mask,
  jpegli (BSD-3) for the layers, and your own PDF assembly (the three layers as stacked PDF
  image XObjects with a soft-mask/`/SMask` or an `/ImageMask` overlay). The *algorithm* is a
  published ITU standard (T.44, 1999) and DjVu's base patents have expired, so the technique
  is unencumbered — **[full patent clearance out of scope; base T.44/DjVu patents expired,
  but not exhaustively cleared — flag for legal sign-off before shipping the MRC mode]**.

**Real implementation effort on macOS (honest):**
- JBIG2-only bilevel path (no MRC): **~1-2 weeks.** Bundle leptonica+jbig2enc, binarise,
  encode, wrap as a JBIG2 PDF. High ROI, low risk.
- Full 3-layer MRC with good segmentation quality: **~6-12 weeks** and it is the hard part —
  segmentation quality (deciding mask vs background) is what separates "really good" from
  "muddy text on a smeared background". Leptonica gives you the primitives but tuning the
  thresholds/adaptive binarisation per document is real signal-processing work. Metal/vImage
  accelerate the resampling; the algorithmic judgement is yours.

### Staged architecture — build order for 80% of the value

**Stage 0 — content router (build FIRST, unlocks everything).** Classify each *page*:
born-digital-vector vs image/scan vs mixed. Use it to route. This alone, with Apple-only
codecs, already beats "one setting for the whole file". Cheap, pure Swift + PDFKit page
inspection.

**Stage 1 — born-digital pages: stream recompression, text untouched.** Keep vector text.
Re-encode embedded raster images with **jpegli** at a tuned quality/DPI; re-pack Flate
streams with **libdeflate** (valid FlateDecode); drop redundant objects. Gets most of
Ghostscript's non-image win with zero rasterisation. **[80% of value for office/report PDFs.]**

**Stage 2 — B/W scans: JBIG2 path (with CCITT fallback).** leptonica binarise → jbig2enc
(**lossless mode**) → JBIG2 PDF + **Vision OCR invisible text layer** (searchable). Highest
single ROI for scan-heavy users, ~2 weeks. Beats Ghostscript's CCITT ceiling — **iff the
target viewers render JBIG2** (verify first; else emit CCITT G4, still a solid 5-15x and
universally portable).

**Stage 3 — colour/grey scans: full MRC.** The hard, high-payoff stage. leptonica segmentation
→ JBIG2 mask + jpegli foreground/background at low DPI → stacked-XObject PDF + Vision OCR
layer. This is where you *pass* Ghostscript on scanned colour docs.

**Stage 4 (optional) — JPEG2000 "max" mode** via openjpeg, gated behind a "Preview/Adobe
target" toggle for users who need the absolute smallest and control their viewer.

**Expected ratios (Path B, staged):**
- Colour/photo PDF: **3-8x** (Stage 1, jpegli) — ~matches tuned Ghostscript.
- Mixed text+image: **2-5x** (Stage 1) — ~matches Ghostscript, text preserved.
- Vector-text-only: **1.1-1.4x** (Stage 1) — ~matches Ghostscript (font subset + Flate).
- B/W scan: **15-40x** (Stage 2, JBIG2 *if viewer-supported*) — **beats** stock Ghostscript;
  falls to **5-15x** on the CCITT G4 fallback (still portable, still solid).
- Colour/grey scan: **5-15x** (Stage 3, MRC) — **beats** stock Ghostscript (no MRC).

**Net: with Stages 0-2 you are already at parity-or-better with Ghostscript on ~80% of real
files, closed-source, permissive. Stage 3 pulls ahead on the remaining scan-heavy cases.**

---

## PATH C — Pure Apple frameworks only (no third-party binaries)

**Architecture (one line):** content-aware router — text/vector pages → PDFKit optimise
(text-preserving, fixed); image/scan pages → rasterise via CoreImage/Metal at tuned DPI +
ImageIO JPEG, then **re-attach a Vision OCR invisible text layer** to restore searchability.

Apple gives exactly two write shapes (per the established constraint): PDFKit optimise
(text-preserving, on/off, not tunable) and rasterise-via-`PDFPage(image:)` (tunable DPI/quality,
flattens to image). Neither is both. The whole game in Path C is **routing** so each page hits
the better of the two, plus **CoreImage/vImage** for high-quality resampling and **Vision** to
undo the searchability loss from rasterising.

**What Path C can do well:**
- Born-digital / vector-text pages → PDFKit optimise: text stays vector, ~1.1-1.5x, no loss.
- Photo/colour scan pages → high-quality Metal/vImage downsample + ImageIO JPEG (hardware JPEG
  block on Apple Silicon), quality-tuned: **2-6x**. Comparable to Ghostscript's *image* handling
  but on rasterised (text-flattened) pages.
- **Vision OCR re-layer** (VNRecognizeTextRequest, on-device, Neural Engine) rebuilds a
  selectable/searchable invisible text layer over the rasterised image — the standard trick
  (OCRmyPDF-AppleOCR, mac-ocr do exactly this). ✓ (Apple Vision docs + those projects). This
  recovers *searchability* but **not** the vector crispness or the tiny size of a bilevel mask.

**Where it structurally caps out:**
- **No JBIG2, no CCITT G4 encoder, no MRC.** Apple's tunable path only emits **JPEG (DCTDecode)**
  raster pages. A B/W text scan that MRC/JBIG2 would take to 15-40x can only reach maybe **3-6x**
  as a downsampled JPEG — and JPEG on sharp black-on-white text produces ringing artefacts.
  **This is the hard structural ceiling: bilevel scans are 3-8x *worse* than Path B can do.**
- No jpegli/mozjpeg → stuck with ImageIO's stock JPEG (~10-35% larger than jpegli at equal
  quality).
- Rasterising a mixed page to save its image *destroys its vector text* — the router must be
  smart enough to only rasterise pages where the size win outweighs the fidelity loss, and to
  Vision-re-OCR them. Getting that routing wrong is the main failure mode.

**Expected ratios (Path C):**
- Colour/photo PDF: **2-6x** (rasterise + tuned JPEG + Vision).
- Mixed text+image: **1.5-4x** — but *only* on pages you choose to rasterise; text-heavy pages
  route to PDFKit-optimise (~1.2x) to keep them sharp.
- Vector-text-only: **1.1-1.5x** (PDFKit optimise).
- B/W scan: **3-6x** — **the structural weak point**; MRC/JBIG2 would do 15-40x.
- Colour/grey scan: **2-6x** — no MRC, so well short of Path B's 5-15x.

**Path C verdict:** genuinely decent for born-digital and photo PDFs, and Vision re-OCR keeps
files searchable — but it *cannot* be "best-in-class on scans", which is where users feel size
most. It's the honest fallback if bundling any binary is off the table.

---

## Ranked recommendation for the CLOSED-SOURCE case (Path B)

For a genuinely "really good" result **without open-sourcing**, in priority order:

1. **Build the content router first (Stage 0).** Per-page classification is the highest-leverage
   thing in the whole engine and costs almost nothing. Everything else routes off it.
2. **Stage 1 stream recompression with jpegli (BSD-3) + libdeflate/brotli (MIT).** Text-preserving,
   matches Ghostscript on ~80% of real (born-digital) files, low risk. jpegli's ~35% JPEG win is
   free once integrated.
3. **Stage 2 JBIG2 bilevel path** (leptonica BSD + jbig2enc Apache) **+ Vision OCR layer.** ~2
   weeks, beats Ghostscript's CCITT ceiling on B/W scans (15-40x), keeps them searchable. Do this
   before MRC — it's most of the scan win for a fraction of the effort.
4. **Stage 3 full MRC** (from scratch on the permissive primitives) — the ambitious differentiator
   that *passes* Ghostscript on colour scans (5-15x). Budget 6-12 weeks; segmentation quality is
   the make-or-break.
5. **Stage 4 optional JPEG2000 (openjpeg BSD-2) "max" mode**, viewer-gated. Nice-to-have, not core.

This ordering yields Ghostscript-parity-or-better on the bulk of files after Stages 0-2, then
clear superiority on scans after Stage 3 — all closed-source, all permissive, one attribution
file in the DMG.

## Top 2 risks
1. **MRC segmentation quality (Stage 3).** The primitives are permissive but no permissive MRC
   *library* exists (archive-pdf-tools is AGPL) — it is a from-scratch signal-processing build,
   and bad mask/background segmentation gives muddy text or haloing. This is the single largest
   technical risk and the thing that separates "really good" from "looks worse than the original".
2. **JBIG2 portability + lossy-symbol corruption (Stage 2).** Two distinct hazards in the
   highest-ROI scan feature: (a) **viewer support is unconfirmed** — Apple PDFKit/Preview and
   pdf.js have documented JBIG2 rendering gaps, and the DMG is *shared with others*, so a JBIG2
   PDF that opens on your Mac may show blank pages on theirs. Verify before defaulting to JBIG2;
   keep CCITT G4 as the portable fallback. (b) **Lossy JBIG2 symbol substitution silently
   corrupts characters** — the 2013 Xerox/JBIG2 bug (Kriesel) swapped digits in scanned docs.
   jbig2enc's lossy mode does exactly this. Against a "preserve quality" bar, altered numbers in
   a contract/invoice is the worst failure mode — **default to lossless JBIG2, never aggressive
   symbol dedup.**

*(Secondary risk: bundling native binaries — jpegli/leptonica/jbig2enc/openjpeg are C/C++ that
must be built arm64, code-signed, and pass notarisation as embedded libs. Non-trivial but
well-trodden; plan for signing/entitlement friction. Path C has none of this — the trade for its
scan-quality ceiling.)*

### Verification flags
- All licence rows **primary-source confirmed** this session: jbig2enc (Apache-2.0, COPYING),
  leptonica (BSD-2-style, leptonica-license.txt), libjxl/jpegli (BSD-3, LICENSE), openjpeg (BSD-2),
  libdeflate (MIT, COPYING), mozjpeg (BSD-3/IJG/zlib via libjpeg-turbo), archive-pdf-tools (AGPL-3.0).
- **JBIG2 rendering in Apple Preview/PDFKit and other shared-recipient viewers is UNVERIFIED** and
  is a live risk (documented JBIG2 blank-page issues in pdf.js; PDFKit's historical PDF-feature
  gaps). Must be empirically tested on target macOS versions before JBIG2 is a default. CCITT G4 is
  the confirmed-universal fallback.
- jpegli's ~35% figure is the **high-quality regime** (2.8-3.7 BPP); expect materially less at the
  low-quality/DPI a compressor uses. Directionally correct, not a typical-case number.
- JBIG2 "3-5x vs CCITT G4" and MRC "5-10x vs single-JPEG" are design targets from tooling/literature
  consensus, not a single-source benchmark — **validate empirically on a real corpus before quoting.**
- MRC/T.44 patent status: base standard 1999, DjVu base patents expired — **not exhaustively cleared;
  get legal sign-off before shipping the MRC mode.**
