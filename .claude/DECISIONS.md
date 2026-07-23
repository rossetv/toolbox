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

## 2026-07-23 — Restate GATES.md in the validator's stanza grammar (no gate removed)

The gate file used free-form `## G1…G4` headings. The push-gate validator rejected it
outright — "no gates and no `no-gates:` claim" — so the repository effectively had **no
parseable gates at all**. Rewritten into the required `### gate: <id>` stanza grammar.

The rewrite deletes 35 lines of prose, which the validator's line-count heuristic reports
as a possible removal. It is not one. Of the seven gates now declared, four preserve a previous
check unchanged, two strengthen a check that was previously only prose, and one is new:

| previous check | now | change |
|---|---|---|
| `scripts/build-ghostscript.sh` + `gs --version` | `gate: ghostscript-builds` | preserved |
| `otool -L` (prose only — never a runnable check) | `gate: ghostscript-self-contained` | **strengthened**: now an executable gate |
| `xcodegen generate` | `gate: project-generates` | preserved |
| `xcodebuild build` | `gate: builds` | preserved |
| `xcodebuild test` | `gate: tests` | preserved |
| `scripts/package-dmg.sh` | `gate: packaged-app-compresses` | **strengthened**: now asserts the packaged app really compresses (`SMOKE PASS`) |
| — | `gate: no-personal-corpus-references` (semantic) | **added** |

**Why:** an unparseable gate file is not a pass, and it silently disabled the whole gate
mechanism. No gate was removed, weakened, or made easier to satisfy; gate coverage strictly
increased, and every mechanical command was run before being written here.

**Provenance:** monocratic (opus). No panel was convened because nothing was removed or
weakened — the panel requirement guards against lowering a standard, and this raises it.
Flagged explicitly in the build report so the maintainer can review and object.

## 2026-07-23 — Scrub a second personal-path leak (design-mockup directory)

A pre-push adversarial review found a second, independent leak the first scrub missed: the
absolute path to the maintainer's local design-mockup directory, exposing the macOS account
name and home-folder layout. It sat in `.claude/plans/` and — worse — in two **shipping source
files** (`DesignSystem/Components.swift`, `DesignSystem/Theme.swift`), across 35 branch commits.

The first scrub missed it because the search deliberately excluded the mockup directory as
"not the PDF corpus". That was a rationalisation of exactly the kind `GATES.md` warns about:
`gate: no-personal-corpus-references` exists because **this repository becomes public**, and the
path identifies the maintainer's machine regardless of which directory it names.

**Resolution:** all three sites abstracted to "the Claude Design mockup (kept outside this
repository)", and the branch history rewritten with `git filter-repo` before the first push.

**Why it matters beyond this instance:** a privacy rule scoped to one named artefact will be
read narrowly. The gate's assertion is therefore to be applied by its `why` — nothing that
identifies the maintainer's machine — not by the literal noun it happens to mention.

**Provenance:** adversarial review (opus) → monocratic fix (opus).

## 2026-07-23 — Gate-command edits: harden two mechanical gates and broaden the semantic one

Logged because `GATES.md` requires that *editing* a gate be recorded, not only removing one.
All three changes strictly strengthen; none makes a gate easier to satisfy, so no panel was
convened (same precedent as the stanza-grammar entry above).

- `gate: ghostscript-self-contained` — now prefixed `test -x Resources/ghostscript/bin/gs && …`.
  Previously, if the binary was **absent**, `otool` produced nothing, the `grep -qv` found no
  offending line, and the gate reported **green on a missing binary**.
- `gate: packaged-app-compresses` — now stages into `mktemp -d` under a `trap … EXIT` that
  detaches the mount and removes the directory. Previously it used a fixed `/tmp/PDFToolbox.app`:
  on a shared machine a directory owned by another user cannot be removed (`/tmp` is sticky), the
  `rm` would fail silently and `cp -R` would land beside a stale bundle — a false green.
- `gate: no-personal-corpus-references` (semantic) — assertion broadened from "the private PDF
  corpus" to anything identifying the maintainer's machine, and instructs that it be applied by
  its intent rather than its literal nouns.

**Why the last one:** the original wording named only the PDF corpus, and a second leak (an
absolute path to a local design-mockup directory, in two shipping source files) was missed
because it fell outside that literal noun while sitting squarely inside the gate's purpose. A
rule that can be satisfied on a technicality is not a gate.

**Provenance:** adversarial review (opus) → monocratic fix (opus).

## 2026-07-23 — Sidebar lists only built tools ("Soon" placeholders removed)

Spec §7 pinned a fixed four-entry sidebar in which `merge` and `split` appeared as dimmed
"Soon" placeholders. They are removed: the sidebar now lists only Compress and OCR.

**Why:** the maintainer's instruction — "no point of having tools that don't exist there".
Advertising a control that cannot do anything is worse than not showing it, and the placeholders
carried real cost: an `isAvailable` flag threaded through the model, disabled-state handling and
a `PlaceholderToolView`, all of it dead weight for features that do not exist.

**Provenance:** human decision, which overrides the spec. `Tool` now has only the built cases and
`isAvailable` is gone entirely; re-adding a tool means adding a case when it is actually built.

## 2026-07-23 — jbig2enc/leptonica native path removed; Rung 2 ships on ImageIO CCITT, no native library

**Decision:** The native jbig2enc/leptonica encoder path is removed entirely. Rung 2 (bilevel-scan
compression) ships on ImageIO's built-in CCITT Group 4 encoder instead; the app links no native or
bespoke image-compression library.
**Why:** The jbig2enc/leptonica experiment was abandoned but left a dead `.cpp` in the compile
sources and header/library search paths in `project.yml` pointing at a git-ignored tree. No Swift
code ever referenced a native symbol, so the path was pure dead weight — but it was live enough to
break the build: the project built and gated green only on the one machine that still had that
tree, and CI would have failed on the first push. CCITT via ImageIO needs no C interop and delivers
the saving Rung 2 exists for.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/compress.md, OVERVIEW.md, docs/ARCHITECTURE.md
**Supersedes:** 2026-07-22 — Rung 2 (JBIG2/CCITT) and Rung 3 (MRC) are out of scope for v1 — the
Rung-2 half only: Rung 2 is now built (on CCITT, not JBIG2). Rung 3 (MRC) remains out of scope.

## 2026-07-23 — Sidebar tool tiles use per-tool colours, diverging from DESIGN.md's single-accent rule (deliberate)

**Decision:** `Tool.tint` gives each sidebar tool tile its own colour (Compress red, OCR purple)
rather than reusing the single Apple-Blue accent `DESIGN.md` specifies for the whole app. This is a
deliberate, recorded divergence — not a defect to silently "fix" back to blue.
**Why:** The repo owner explicitly asked for fidelity to the original design mockup, which gives
each tool tile its own colour. `Theme` already carried non-blue tokens before this branch
(`Theme.Colors.success`, `Theme.Colors.documentBadge`), so this widens an existing precedent rather
than introducing a first departure. `DESIGN.md` is human-owned (`.claude/CLAUDE.md` § Design & UI
Consistency) — reconciling its single-accent rule with per-tool tile colours is the owner's
amendment to make; Claude does not edit `DESIGN.md` unasked.
**Affects:** docs/modules/app.md, docs/modules/design-system.md

## 2026-07-23 — PDFWriter now indexes and supersedes objects packed in `/ObjStm` streams

**Decision:** `PDFWriter` no longer fails loud on every object-stream PDF. It indexes every object
packed into a compressed object stream (`PDFSyntax` + `PDFFlate.inflate`, budget-bounded) and
supersedes one by emitting an **uncompressed top-level object of the same number** in the appended
section — the newest cross-reference entry for an object number wins (PDF 32000-1 §7.5.6), so the
object stream itself is never rewritten. `.unsupportedStructure` now fires only when a page or the
catalog it must supersede sits in an object stream the writer cannot read (an unsupported filter, a
`/DecodeParms` predictor, a truncated body) or otherwise cannot be resolved.
**Why:** The blanket refusal excluded a meaningful share of a representative corpus from OCR
entirely (Acrobat routinely packs the catalog/page tree into object streams). `PDFSyntax`'s
byte-level scanner and `PDFFlate`'s bounded zlib inflate make reading them safely for this purpose.
The verbatim-prefix incremental-update guarantee is unaffected — appended objects still just append.
**Spec:** .claude/specs/20260722-pdf-toolbox-v1.md
**Affects:** docs/modules/services.md
**Supersedes:** 2026-07-22 — PDFWriter fails loud on object-stream (`/ObjStm`) PDFs — that entry's
blanket refusal is replaced by the parse described above; `.unsupportedStructure` remains the
fail-loud outcome only for streams the writer genuinely cannot read.
