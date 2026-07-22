# PDF Compression Engine — Decision-Grade Research (native macOS 26 app)

Scope: a SwiftUI/AppKit app that compresses large PDFs → smaller PDFs. Three distribution modes matter and pull in different directions: **personal** (your machine only), **notarised DMG outside the App Store** (Developer-ID signed, distributed to others), and **Mac App Store (MAS)** (sandboxed). Licensing and the sandbox, not raw quality, decide the winner in two of the three.

---

## TL;DR recommendations by distribution mode

| Mode | Recommended engine | One-line reason |
|---|---|---|
| **Personal** | Ghostscript (`gs pdfwrite`) via `Process` | Best quality/ratio, zero licensing exposure because you never *distribute* it, sandbox irrelevant. |
| **Notarised DMG (closed source, outside MAS)** | **Native custom CoreGraphics/PDFKit pipeline** (default). Ghostscript only if you buy an Artifex commercial licence. | AGPL forbids bundling GS in a closed-source distributed app; native has no licence and notarisation allows a bundled binary but the *licence* is what bites. |
| **Mac App Store (sandboxed)** | **Native only** (PDFKit write options and/or custom CoreGraphics) | AGPL is incompatible with the closed MAS binary, and MAS review/sandbox make a bundled GS a non-starter in practice. Native system frameworks are the only clean path. |

The native pipeline is the through-line: it is the *only* option that works in **all three** modes with no licence cost. Build native first; treat Ghostscript as a personal-mode power tool or a paid upgrade.

---

## The engines

### 1. Apple Quartz / ColorSync "Reduce File Size" filter

The built-in `/System/Library/Filters/Reduce File Size.qfilter` (exposed in Preview's Export ▸ Quartz Filter and in ColorSync Utility), or a `QuartzFilter` applied while drawing a `CGPDFDocument` into a `CGPDFContext`.

- **(a) Quality/ratio:** Bad and unpredictable. The stock filter downsamples **every** image to max 512 px on the long edge and scales resolution ~50% ([OWC/MacSales](https://eshop.macsales.com/blog/63995-reduce-pdf-size-control-quality-for-free/), [diurnal.st](https://diurnal.st/2021/03/10/mac-reduce-pdf-size-custom-filter.html)). For scanned pages where the whole page is one image, 512 px renders the document illegible. It **routinely inflates files**: documented cases include 15.7 MB → 53.5 MB ([Apple Community 253444095](https://discussions.apple.com/thread/253444095), [MacScripter 73423](https://www.macscripter.net/t/applying-quartz-filters-increase-sizes-from-existing-file-size/73423)) — it re-encodes already-efficient streams badly and can add rather than remove data. Some PDFs see near-zero reduction.
- **(b) Configurability:** You can clone the `.qfilter` (an XML plist) in ColorSync Utility and edit the `ImageSizeMax` / compression-quality keys, so it is *marginally* tunable — but it's a coarse, poorly documented knob set, not a preset system, and you'd have to ship and load a custom `.qfilter`.
- **(c) Deps/bundle:** Zero — system framework.
- **(d) Licensing:** None (Apple system API).
- **(e) MAS sandbox:** Compatible (pure CoreGraphics/ColorSync, no external process).
- **(f) Effort:** Low to wire up; **high to make acceptable**, which you can't — the quality ceiling is the problem, not the integration.
- **macOS 26 state:** This is a legacy, effectively unmaintained ColorSync filter. The 512 px / 50% behaviour and the inflation reports span many OS releases and there is **no evidence macOS 26 changed it**. Treat it as decade-old baggage. **Verdict: do not build on it.** Its only value is as the negative baseline that justifies doing the work properly.

### 2. Custom CoreGraphics / PDFKit pipeline — the native option (LIKELY WINNER)

This is not one design; it is **three sub-approaches** with very different effort and fidelity. Choosing among them is the core engineering decision.

**2a. PDFKit write options (trivial, opaque, text-preserving).** Since macOS 13 Ventura / iOS 16, `PDFDocument.write(to:withOptions:)` / `dataRepresentation(options:)` accept `PDFDocumentWriteOption` keys **`saveAllImagesAsJPEG`** and **`optimizeImagesForScreen`** ([WWDC22 "What's new in PDFKit"](https://developer.apple.com/videos/play/wwdc2022/10089/), [PDFDocumentWriteOption](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption)). `saveAllImagesAsJPEG` forces JPEG (DCTDecode) encoding on every image; `optimizeImagesForScreen` downsamples to a max of HiDPI screen resolution. Combined, that's Apple's own "make it smaller" path — **~10 lines of Swift**, preserves the text/vector layer, and Apple internally handles masks/colour spaces.
  - **Cost:** it is **not tunable.** No exposed JPEG-quality parameter, no target-DPI parameter — "HiDPI screen resolution" is a fixed internal target ([WWDC22 transcript confirms binary switches, no quality/DPI values](https://developer.apple.com/videos/play/wwdc2022/10089/)). It gives you *one* preset. If your product promise is "quality presets / target DPI / image-quality slider", this alone does not deliver it. Excellent as a fast default and a fallback; insufficient as the whole engine.

**2b. Rasterise-and-rebuild (easy, fully tunable, destroys structure).** For each page, render to a `CGImage` at a chosen DPI, JPEG-encode via `CGImageDestination` at a chosen `kCGImageDestinationLossyCompressionQuality`, and build a new page with `PDFPage(image:)`. **Fully tunable** on DPI and quality, straightforward to write.
  - **Cost:** it **flattens everything to a single raster per page** — kills real text, selectable/searchable content, the invisible OCR layer scanned PDFs often carry, vectors, links, and annotations. Fine for pure photographic scans that are *already* page-images; unacceptable for text/vector or OCR'd PDFs.

**2c. Surgical image-XObject replacement (tunable AND text-preserving — the expensive quadrant).** Walk the PDF, find each image XObject, downsample+re-encode it, and write it back while leaving text and vectors untouched. This is what a real "PDF compressor" does. **This is the hard one, and here is the single biggest structural obstacle:**
  - **Apple gives you no in-place PDF-editing API.** `CGPDFDocument` is **read-only**; `CGPDFContext` only *creates a new* PDF by drawing. There is no CoreGraphics/PDFKit call that replaces an existing image stream in place ([Quartz 2D PDF guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf/dq_pdf.html); confirmed read-oriented). So 2c means either (i) low-level object-graph surgery reading `CGPDFStream`/`CGPDFDictionary` and **hand-serialising a new PDF file** (writing the xref table, object streams, etc. yourself — a large, bug-prone undertaking), or (ii) adopting a third-party PDF library that can edit objects. There is no cheap native 2c.

**Hard parts of the native custom pipeline (2b/2c), scrutinised:**
- **No in-place edit API (2c).** The top risk, above. Rewriting PDF structure by hand is where projects die.
- **Image masks & soft masks (SMask).** An image can carry a separate stencil mask or an alpha `SMask` stream. Downsample/re-encode the base image without re-registering and re-sampling the mask at matching dimensions and you get misaligned edges, lost transparency, or black boxes. JPEG (DCTDecode) **cannot carry alpha**, so masked/transparent images can't naively become JPEG — you must keep the mask as a separate stream or fall back to Flate.
- **Colour spaces / CMYK.** PDF images may be DeviceCMYK, ICC-based, Indexed (palette), Separation, or Lab. CGImage → JPEG round-trips risk colour shifts; **CMYK JPEG** specifically is a minefield (Adobe's inverted-CMYK APP14 convention) and CoreImage/CoreGraphics may convert to RGB, changing colours and breaking print intent. Indexed/1-bit images must be handled specially or they balloon.
- **Bilevel (black-and-white) scans — the real quality gap.** For B/W document scans, the right codec is **JBIG2 or CCITT Group 4**, which Ghostscript emits: far smaller *and* cleaner than JPEG, which rings/smears on sharp text edges. **CoreGraphics will not emit JBIG2/CCITT for PDF embedding** — a JPEG-only native pipeline is therefore *both larger and uglier* on exactly the bilevel-scan case. This is the single most citable quality deficit vs Ghostscript (see §"quality gap").
- **Transparency / blend groups.** Transparency groups, blend modes and knockout groups must be preserved; 2b flattening changes compositing, 2c must leave them alone.
- **Downsampling artefacts.** Naive decimation aliases; you want a proper resample (Lanczos/area-average via CoreImage `CILanczosScaleTransform` or `vImage`) and sensible DPI thresholds (don't upsample; skip images already below target).
- **Preserving text/vectors.** Only 2a and 2c preserve them; 2b does not. If searchability/OCR matters, 2b is out.
- **Re-assembly & correctness.** Object dedup, xref/linearisation, font subsetting (native won't re-subset fonts — Ghostscript does), and not corrupting the file. Validate output opens in Acrobat/Chrome/Preview, not just PDFKit.

**Net on option 2:** Ship **2a as the default one-click** path and **2b for a "maximise compression on scans" preset** (tunable DPI+quality) — together they cover most real files with a few hundred lines and no licence. Reserve **2c** for later; if you truly need tunable-and-structure-preserving, that's when a paid third-party PDF SDK or an Artifex GS licence earns its keep. **(a)** ratios: on image-heavy scans, 2b at 150 DPI / JPEG q0.6 lands in the same ballpark as GS `/ebook` (70–90% reduction is normal for scans, cf. [qpdf discussion](https://github.com/qpdf/qpdf/discussions/1186)); on vector/text PDFs there's little image data to shrink, so all engines save little and 2b is *harmful* (rasterises text). **(b)** fully tunable (2b/2c), fixed (2a). **(c)** zero deps. **(d)** no licence. **(e)** fully MAS-sandbox-compatible — system frameworks, no subprocess. **(f)** 2a: hours. 2b: days. 2c: weeks-to-months or a paid SDK.

### 3. Ghostscript (`gs -sDEVICE=pdfwrite -dPDFSETTINGS=…`)

- **(a) Quality/ratio — gold standard.** Presets map to image DPI: `/screen` 72 dpi (smallest), `/ebook` 150 dpi (balanced), `/printer` 300 dpi, `/prepress` 300 dpi + colour preservation ([ghostscript.readthedocs VectorDevices](https://ghostscript.readthedocs.io/en/latest/VectorDevices.html), [modest-destiny](https://blog.modest-destiny.com/posts/pdf-compression-with-ghostscript/)). Real results: 16 MB → 866 KB with no obvious quality loss on image-heavy input ([aakashnand](https://aakashnand.com/til/compress-pdf-ghostscript/)). It downsamples images, recompresses (JPEG for colour, JBIG2/CCITT for bilevel), subsets fonts, dedupes objects and rewrites structure — the mature, well-tuned combination is why it wins. Caveat: on *small text-only* PDFs it can produce a **larger** file, so gate it by measuring output vs input.
- **(b) Configurability — excellent.** Presets plus fine control: `-dColorImageResolution`, `-dDownsampleColorImages`, `-dColorImageDownsampleType`, `-dJPEGQ`, per-image-type knobs. This is the most tunable engine.
- **(c) Deps/bundle:** the `libgs` dylib alone is ~13 MB ([observed libgs.9.53.dylib ≈ 13.6 MB](https://trac.macports.org/ticket/61479)); a working bundle with fonts/resources is **tens of MB (~20–40 MB)**. Non-trivial bundle bloat.
- **(d) LICENSING — the decider. Ghostscript is AGPL v3, dual-licensed by Artifex.** Per the [Ghostscript FAQ](https://ghostscript.com/faq/): the AGPL path is *"for developers who wish to share their entire application source code…under the AGPL 'copyleft' terms"* and is only free-of-obligation if you use it *"unchanged and won't be distributing it."* And bluntly: *"As soon as you want to distribute Ghostscript in a closed source, proprietary environment…you have to purchase an Artifex commercial licence,"* and *"if you cannot (or are not prepared to) either follow the terms of the AGPL or get a commercial licence from Artifex, then you may not use Ghostscript in any software that you distribute, on pain of legal action."*
  - **Per distribution mode:**
    - **Personal (no distribution):** AGPL imposes **no obligation** — you aren't conveying the software. Use GS freely. ✅
    - **Notarised DMG, closed source:** Bundling GS triggers AGPL §13/§5 — you would have to **release your entire app's source under AGPL** to every recipient. For a closed-source app that's a non-starter; the alternative is a **paid Artifex commercial licence** (removes all copyleft obligations). So: viable only if open-source *or* if you pay. ❌ for closed-source-free.
    - **MAS:** AGPL is **fundamentally incompatible with the App Store** (App Store DRM + terms conflict with AGPL's anti-DRM/relinking freedoms; the MAS binary is closed). Commercial licence doesn't rescue it either, because of (e). ❌
- **(e) MAS sandbox — NOT compatible; confirmed, with the precise reason.** Under App Sandbox you **cannot `Process`/`NSTask` a binary outside the app bundle** — it fails with "launch path not accessible" / `deny(1) forbidden-sandbox-reinit` ([Apple Forums 30319](https://developer.apple.com/forums/thread/30319), [683158](https://forums.developer.apple.com/forums/thread/683158)). The one nuance to be honest about: a MAS app **may** launch a helper tool *embedded in the bundle* if that tool is signed with **exactly** `com.apple.security.app-sandbox` + `com.apple.security.inherit` ([Twocanoes](https://twocanoes.com/adding-a-command-line-tool-helper-to-a-mac-app-store-app/), [timac.org](https://blog.timac.org/2021/0516-mac-app-store-embedding-a-command-line-tool-using-paths-as-arguments/)). So GS is not *technically* impossible to launch in a sandbox — **but the real killers are (1) the AGPL/App-Store licence incompatibility above, which forbids it regardless, and (2) an inherited sandbox confines GS to files the parent granted, plus MAS review scrutiny of a large embedded GPL binary.** Do **not** frame it as "technically impossible"; frame it as "licensing forbids it, and it's the wrong tool for a sandbox."
- **(f) Effort:** Low to integrate via `Process` (build the arg string, run, read output) *where allowed* (personal/notarised). The effort is not code — it's the **licence decision and the bundle/signing/notarisation of the GS binary**.

### 4. Also-rans (brief)

- **qpdf** — MPL-2.0 (permissive, *no* copyleft trap; safe to bundle closed-source). But it does **lossless / structural** optimisation only: stream (re)compression, object dedup, linearisation. It **does not recompress images.** On image-heavy PDFs the savings are tiny — measured **10 MB → 9.49 MB** with `--compress-streams=y --recompress-flate --optimize-images` ([qpdf#1402](https://github.com/qpdf/qpdf/issues/1402), [discussion 1186](https://github.com/qpdf/qpdf/discussions/1186)). Already-JPEG images can't be shrunk losslessly. **Use it as a *finishing pass* after image recompression (linearise + dedup), never as the compressor.** ~a few MB bundle.
- **MuPDF / mutool** — **same AGPL trap as Ghostscript** (both are Artifex; dual AGPL/commercial). Per [Artifex/MuPDF licensing](https://mupdf.readthedocs.io/en/1.27.2/license.html): *"If you link MuPDF into your own software, then the entirety of that software must be licensed under the GNU AGPL,"* else buy a commercial licence. So identical distribution problem to GS: fine for personal, needs a paid licence for a closed notarised/MAS app. It *is* a C library (linkable, no subprocess) so it could run inside a sandbox technically — but AGPL still forbids the closed-source build. No advantage over GS on the axis that matters.

---

## Master comparison

| | 1. Quartz filter | 2a. PDFKit opts | 2b. Rasterise-rebuild | 2c. XObject surgery | 3. Ghostscript | qpdf | MuPDF |
|---|---|---|---|---|---|---|---|
| **Scanned ratio** | Erratic, can inflate | Good (1 preset) | 70–90% | 70–90% | **70–95%, best** | ~5% | ~best (=GS class) |
| **Vector/text ratio** | Poor | Small (safe) | N/A (destroys text) | Small (safe) | Small–moderate, safe | Small, safe | Small, safe |
| **Tunable (DPI/quality)** | Barely (edit .qfilter) | ❌ one preset | ✅ full | ✅ full | ✅✅ full | n/a (lossless) | ✅ |
| **Preserves text/vectors/OCR** | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Deps / bundle** | 0 | 0 | 0 | 0 (or 3rd-party SDK) | ~20–40 MB | few MB | ~tens MB |
| **Licence** | Apple | Apple | Apple | Apple | **AGPL / paid** | MPL-2.0 ✅ | **AGPL / paid** |
| **Closed notarised OK?** | ✅ | ✅ | ✅ | ✅ | ❌ (unless paid) | ✅ | ❌ (unless paid) |
| **MAS sandbox OK?** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ (licence) |
| **Effort** | Low (but useless) | **Hours** | **Days** | Weeks–months | Low code / licence pain | Low | Low code / licence |

---

## The realistic native-vs-Ghostscript quality gap

- **Colour photographic / mixed scans:** **Small.** Both ultimately emit **JPEG (DCTDecode)** for lossy colour images; a native 2b/2c pipeline that downsamples to the same DPI (e.g. 150) and picks a sane JPEG quality lands within a few percent of GS `/ebook`. The gap here is *tuning maturity* (GS has better default resample + thresholds), not codec. A careful native pipeline closes most of it.
- **Bilevel black-and-white scans (the classic "image-heavy scanned PDF"):** **Large, and it favours Ghostscript.** GS emits **JBIG2/CCITT G4** for 1-bit images — dramatically smaller than JPEG *and* free of JPEG ringing on text. CoreGraphics won't produce JBIG2/CCITT for PDF embedding, so a JPEG-only native pipeline is both **bigger and visibly worse** on these. This is the one case where "just build native" leaves real quality/size on the table.
- **Fonts & structure:** GS re-subsets fonts, dedupes and rewrites the object graph; the native pipeline generally won't, so on font-heavy or bloated-structure PDFs GS wins independent of images. (Mitigate with a qpdf finishing pass.)
- **Overall:** for a general-purpose consumer compressor, native gets you **~80–90% of GS's result on colour scans and mixed docs** with zero licence cost; GS's decisive edge is **bilevel scans and heavily-structured/font-heavy PDFs.**

## Top engineering risks of the native pipeline (ranked)

1. **No in-place PDF image-editing API.** `CGPDFDocument` read-only, `CGPDFContext` create-only. Tunable-*and*-structure-preserving (2c) forces hand-rolled PDF serialisation or a third-party SDK. This is the project-killer; design around it by shipping 2a+2b first.
2. **Bilevel/scan codec gap** (no JBIG2/CCITT) — accept a size/quality deficit vs GS on B/W scans, or special-case them.
3. **Image masks / SMask / transparency** — misalignment, lost alpha, black boxes; JPEG can't carry alpha.
4. **Colour-space correctness, especially CMYK JPEG** — colour shifts, broken print intent, indexed/1-bit blow-ups.
5. **Structure/OCR fidelity** — 2b destroys the searchable text layer; choose per-file between 2a/2b, don't blindly rasterise.
6. **Output correctness across viewers** — validate in Acrobat/Chrome, not just PDFKit; never emit a file larger than the input (measure and keep the smaller).
