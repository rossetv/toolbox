# Decisions

<!-- Claude-maintained, append-only. Entries are never edited or deleted; a
reversal gets a new dated entry that names what it supersedes. Every entry
starts with a heading of the form:

    ## YYYY-MM-DD — <short decision title>

kb-context.sh extracts titles by that pattern — this format and that script
are a coupled contract; change them only together, in the CLAUDE repo.

Entry body shape (Spec/Affects/Supersedes lines only when applicable):

    **Decision:** <what was decided>
    **Why:** <the reason — trade-offs considered>
    **Spec:** .claude/specs/<file>.md
    **Affects:** <KB doc paths this decision touches, comma-separated>
    **Supersedes:** <date/title of the earlier entry, only if a reversal>

Delete nothing above when appending; append new entries at the end of file. -->

## 2026-07-22 — Compress engine = Ghostscript-core, bundled and built from source

**Decision:** Compress uses a bundled Ghostscript `pdfwrite` binary, built from
source for arm64 as a single self-contained executable (only `/usr/lib` system
dylibs; its Resource tree embedded in ROM).
**Why:** Ghostscript is the gold-standard text-preserving PDF optimiser and the only
option that delivers three genuinely tunable presets on born-digital documents.
Rejected pure-Apple PDFKit (one fixed optimisation level, can't do tunable presets, no
in-place image edit API) and PDFium (BSD-licensed but buys nothing over GS once AGPL
is already accepted, and forces an MRC implementation from scratch).
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/compress.md, docs/modules/services.md, OVERVIEW.md

## 2026-07-22 — AGPL-3.0, open-source at release; Mac App Store foreclosed

**Decision:** The app ships under AGPL-3.0-or-later once released, forced by the
Ghostscript dependency. Distribution is a notarised DMG, never the Mac App Store
(AGPL-incompatible). The repo stays private during development; it is flipped public
at or before release — AGPL obligations trigger on distribution, so private dev is
compliant.
**Why:** "Best result" was explicitly ranked above "purely native" — accepting AGPL
unlocks Ghostscript for free and, longer-term, lets a colour-scan MRC codec be a port
of an existing AGPL reference rather than a from-scratch implementation.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** OVERVIEW.md

## 2026-07-22 — Every Ghostscript invocation runs inside a seatbelt sandbox

**Decision:** `GhostscriptRunner` never runs gs as a bare `Process`; every invocation
is wrapped in `sandbox-exec` with a profile that denies network, restricts the
filesystem to exactly the input file, the output directory, gs's own resource
bundle, and a per-run scratch dir, plus `-dSAFER`, `-dBATCH`, `-dNOPAUSE` and a
wall-clock cap.
**Why:** Input PDFs are untrusted and Ghostscript has a CVE history (e.g.
CVE-2023-36664) — this is the containment mechanism for that risk, mandatory per
spec §5.4, not optional hardening.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/services.md

## 2026-07-22 — Compress stages all gs I/O through a non-TCC temp working directory

**Decision:** `CompressEngine` copies the input into a private working directory
under the system temp dir before handing anything to the sandboxed gs child, and
copies the result back out on success.
**Why:** A seatbelt-sandboxed child process cannot inherit the parent app's TCC file
grant, so it must never be handed a path directly under a TCC-protected folder
(`~/Documents`, `~/Downloads`, `~/Desktop`) — that would hang on a permission prompt
the non-interactive child can never answer.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/compress.md, docs/ARCHITECTURE.md

## 2026-07-22 — OCR embeds text by PDF incremental update, not in-place edit

**Decision:** `PDFWriter.appendTextLayer` adds the OCR text layer by PDF incremental
update: the original bytes are the verbatim prefix of the output, and only new
objects, a new xref section, and a trailer with `/Prev` are appended.
**Why:** Apple provides no in-place PDF-object edit API. Incremental update
guarantees the original image XObject streams are never rewritten, so "appearance
unchanged" is literally true (and is still independently re-checked by
`OutputValidator`).
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/services.md, docs/modules/ocr.md

## 2026-07-22 — Signing is ad-hoc; notarisation deferred pending an Apple Developer ID

**Decision:** `project.yml` and `scripts/package-dmg.sh` sign ad-hoc (`CODE_SIGN_IDENTITY: "-"`)
by default; CI has guarded notarisation/release steps that only run once the repo
owner supplies Developer ID secrets.
**Why:** No Developer ID certificate exists on the development machine yet; ad-hoc
signing is sufficient to run a locally built app but Gatekeeper will reject a
downloaded ad-hoc DMG — this is a release-time dependency, not a development blocker.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** OVERVIEW.md

## 2026-07-22 — Rung 2 (JBIG2/CCITT) and Rung 3 (MRC) are out of scope for v1

**Decision:** v1 ships Rung 1 only (Ghostscript `pdfwrite` for every document,
regardless of content type). The native scan pipeline (bilevel → JBIG2/CCITT, colour
scan → MRC) spec'd in §5.1 is not built; `PDFContentType`'s colour/bilevel split
exists only to seed that future routing.
**Why:** v1-done is defined as "Rungs 1–2 + OCR solid and shippable", with Rung 3
gated behind a segmentation quality spike; building either before the corpus,
measurement harness, and router baseline exist would yield a worse result.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/compress.md, docs/modules/models.md, docs/ARCHITECTURE.md, OVERVIEW.md

## 2026-07-22 — PDFWriter fails loud on object-stream (`/ObjStm`) PDFs

**Decision:** `PDFWriter` throws `.unsupportedStructure` when a page or the catalog it
must supersede is packed inside a compressed object stream rather than being a
top-level indirect object, instead of attempting to unpack it.
**Why:** v1's minimal top-level tokeniser does not parse object streams; failing loud
on one file (batch continues with the rest) is safer than risking silent corruption.
Compress is unaffected — it never parses PDF structure itself, Ghostscript does.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/services.md, docs/modules/ocr.md
