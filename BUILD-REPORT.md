# PDF Toolbox — overnight build report

*What was built, what was verified, what is deliberately not done, and the one thing that needs you.*

## What you have

A native macOS app — **PDF Toolbox** (SwiftUI, Apple Silicon, macOS 14+, AGPL-3.0) — with two working tools in an extensible sidebar shell (Merge/Split are visible as "Soon").

### Compress — the primary feature, full coverage

- Bundled **Ghostscript 10.07.1**, built from source for arm64 as a **single self-contained binary**: it links only `libSystem` and `libiconv`, with its Resource tree embedded in ROM. No Homebrew, no dylib shipping, nothing to install.
- Every invocation runs inside a **seatbelt sandbox** — `(deny default)`, network denied, filesystem scoped to a private temp working directory, plus `-dSAFER` and a watchdog that escalates to `SIGKILL`. This was proven empirically during review, not assumed: gs launches, egress is blocked, out-of-scope reads are denied.
- Three presets, batch queue with per-file size estimates, optional output folder, working cancel.
- **Your originals are never touched.** Output is written to a temp file and atomically moved into place as `<name>-compressed.pdf`. It never emits a file larger than the input (it reports "already optimised" and writes nothing). Every output is re-validated before it is accepted.

**Measured on your real corpus (58 PDFs, 86 MB).** Only anonymised aggregates were recorded; nothing about your documents exists in the repository.

| Preset | median | mean | **total bytes saved** | ≥50% smaller | no gain |
|---|---|---|---|---|---|
| Balanced *(default)* | 12% | 26% | **50%** | 14/58 | 10 |
| Maximum Quality | 0% | 9% | 5% | 4/58 | 36 |
| Smallest Size | 32% | 43% | **79%** | 27/58 | 9 |

About 60% of your files are already small and lean, which drags the *median* down — but the byte-heavy files compress hard. **Balanced halves your total library size; Smallest Size cuts it by ~80%.** Maximum Quality barely compresses by design: it prioritises fidelity.

### OCR — works, and fails loudly rather than corrupting

- Apple Vision (`VNRecognizeTextRequest`), on-device, with accuracy and language options.
- Adds an invisible searchable text layer by **PDF incremental update**: your original file is the verbatim byte prefix of the output, so **every image is byte-identical** and the page looks unchanged.
- Skips pages that already have text; reports "already searchable" when there is nothing to do. Cancellable.

## Honest limitations — please read

1. **OCR covers ~79% of your corpus.** 12 of your 58 files use `/ObjStm` object streams (typical of Acrobat-optimised PDFs). OCR **declines** those with a clear per-file error rather than risking a bad result. **Compress works on all 58.**
2. **OCR output is validated hard and discarded if anything is off.** An adversarial review found several parsing defects in the incremental-update writer. Rather than hand-patch a PDF tokeniser overnight, the output is now rejected unless the original is its verbatim byte prefix, the structure opens with the same page count, and *every* page that received text still renders and yields extractable text. **Net effect: a writer bug becomes "OCR skipped this file", never a silently corrupt document.** The underlying parser defects are documented for v1.1.
3. **Not notarised — this needs you.** There is no Apple Developer ID certificate on this machine, so the app is ad-hoc signed. That is enough to run it locally; it is not enough to distribute. CI has the signing and notarisation steps written and waiting on credentials.
4. **Rung 2 (JBIG2/CCITT) and Rung 3 (MRC) are not built.** The spec set Rung 1 as the v1 floor. MRC is where the large wins on colour scans would come from — it is the obvious next step.
5. **I could not visually verify the UI.** Screenshotting is gated behind macOS Screen Recording permission, which needs a human click. The app builds, launches cleanly, and the design system is applied across every view and state — but you are the first person to actually *look* at it.
6. **Your commits are authored with your corporate email address**, on a repository you intend to make public — check it with `git log -1 --format='%an <%ae>'`. I have deliberately not written the address here, because this file is itself committed. I did not rewrite your commit authorship either: that is your identity and your call, and you did not ask me to. The repo is still private, so it is cheap to change now if you want to.

## How to test it

The DMG was built on this machine, so it carries no quarantine flag and should open directly.

```sh
open dist/PDFToolbox.dmg     # from the repo root
# drag PDF Toolbox to Applications, then launch it
```

If macOS ever objects — e.g. for a copy downloaded from a GitHub Release rather than this local one:

```sh
xattr -dr com.apple.quarantine /Applications/PDFToolbox.app
```

…or right-click the app and choose **Open**.

## Verified, not claimed

- Full suite: **65 tests, 0 failures**.
- All six mechanical gates in `.claude/GATES.md` run and pass, including one that packages the DMG and asserts the **shipped bundle** really compresses.
- The packaged app, installed from the DMG to /Applications, compressed a real PDF: **3,154,661 → 867,243 bytes (72.5% smaller)**, page count preserved, gs running under the sandbox.
- Gatekeeper behaviour checked directly (`spctl` rejects the unnotarised build; stripping quarantine clears it).

## Two privacy incidents, both mine, both fixed before anything was pushed

1. The committed plan contained the literal path to your private PDF corpus, in every commit since it landed.
2. A **second**, independent leak: the absolute path to your local design-mockup directory — exposing your account name and home layout — in the plan **and in two shipping source files**. My first scrub missed it because I had excluded that directory as "not the PDF corpus", which was exactly the rationalisation the project's own gate file warns about.

Both were scrubbed from the entire branch history with `git filter-repo` and independently verified by a separate reviewer: no commit in any ref, and no tracked file, contains either path. Nothing was pushed until this was clean. A semantic gate now guards the class, applied by its intent — *nothing that identifies your machine* — rather than by the specific directory it names.

**One precise caveat, because the distinction matters:** `git filter-repo --replace-text` rewrites **file content only — never author or committer metadata**. So "no commit contains that path" is a statement about the *files*. Your account name still appears in every commit's identity field as the author address below, which is now the only place it survives. The private directory names and home-folder layout are genuinely gone; what remains is a username and an employer domain.

## What I would do next

1. **MRC (Rung 3)** — the real quality-and-size win on colour scans.
2. **Object-stream support in the OCR writer** — takes OCR from ~79% to ~100% of your corpus.
3. Fix the `PDFWriter` parser findings properly, then relax the validation net.
4. Add your Developer ID and notarisation secrets so CI ships a double-clickable release.
5. Bound `PDFWriter`'s memory (it currently holds whole-file copies) and implement the spec's per-job memory cap.
