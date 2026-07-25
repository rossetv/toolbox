# Toolbox — build report

*What was built, what was verified first-hand, what is deliberately not done, and what needs you.*

Supersedes the previous report: that one predated Rung 3 (MRC), the runner-up switching UI, the
field-fix rounds that followed the first real-world use, and the parallelised test suite — its
"Rung 3 not built" and "155 tests" statements are no longer true.

## Status

| Area | State |
|---|---|
| Compress — Rung 1 (Ghostscript) | shipping |
| Compress — Rung 2 (binarise + CCITT G4) | shipping, including OCR'd scans (text layer preserved, raced against gs) |
| Compress — Rung 3 (MRC, per-page mask/foreground/background) | **shipping** on Balanced/Smallest for colour scans, behind a size race against the gs output |
| OCR (Apple Vision + incremental update) | shipping, including object-stream PDFs |
| UI | driven end-to-end, including the heavy-compression capsule, popover and version switching |
| Tests | **251, 0 failures — 88 s wall** (8 parallel workers) |
| Packaging | DMG builds, installs and compresses |
| Notarisation | **blocked on your Apple Developer ID** |

## Verified, not claimed

Everything here was run and read, not inferred — most of it re-verified for this report:

- Full suite: **251 tests, 0 failures, 88 seconds** with `-parallel-testing-enabled YES`.
- All six mechanical gates in `.claude/GATES.md` pass, including the one that packages the DMG and
  asserts the **shipped bundle** really compresses under the sandbox.
- The packaged Release app was driven through its UI on real scans: a six-page colour scan came out
  at **−70 % (2.5 MB → 744 KB)** with visibly crisp text, an eleven-page colour scan at −70 %, and a
  seven-page black-and-white document at −97 % via CCITT. Output pages were rendered to images and
  inspected by eye: sharp, correctly oriented, colour preserved.
- The heavy-compression capsule, its popover, and switching between the shipped and parked versions
  were exercised in the running app; the capsule label follows the shipped version ("Heavy
  compression" / "Normal compression" / "Original") and the savings badge disappears at zero saving.
- Sandbox containment probed directly: Ghostscript launches, network egress is blocked, and reads
  outside the granted scope are denied.
- Gatekeeper behaviour checked (`spctl` rejects the unnotarised build; stripping quarantine clears it).

## What changed since the previous report

**Rung 3 (MRC) was built and shipped.** Per-page classify → segment → CCITT mask + JPEG
foreground/background layers → verify → compose, weighed per document against the plain gs output;
the loser is parked and the UI offers a switch. Getting it from "ships" to "usable" took two field
rounds:

1. **Upside-down pages.** The renderer bakes a page's `/Rotate` into upright pixels, and the
   composer then re-stamped the original `/Rotate` — so viewers rotated twice. The composers now
   never emit `/Rotate`; the guarding test compares rendered pixels against a viewer-true reference
   instead of trusting metadata (which is how the bug had hidden).
2. **Blurry text.** The CCITT text mask is applied as the foreground JPEG's soft-mask, and viewers
   resample the mask down to the foreground image's pixel grid — a foreground stored at low
   resolution therefore smeared every glyph regardless of mask sharpness. The foreground is now
   emitted near the mask's resolution, the fill under it is flat, and the render is capped at the
   source scan's resolution; output became sharper **and** smaller (and roughly 3× faster).

**Rung 2 was opened to OCR'd scans.** A scanned document that this app's own OCR tool had processed
carried a text layer, which the classifier read as "born-digital" — so the scan never reached CCITT
and lost its −90 %-class win. Classification now keys on full-page image coverage, the CCITT rebuild
is raced against the gs candidate (so a noisy scan on which CCITT loses simply ships gs — opening
the routing cannot regress any document), and the OCR text layer is re-embedded through the same
writer the OCR tool uses, declining to gs whenever it cannot be re-embedded faithfully.

**UI field fixes.** The heavy-compression capsule label now follows the shipped version after a
switch; stray macOS 26 focus rings after mouse clicks were cleared via the existing
clear-on-click focus pattern (keyboard focus rings remain); Quick Look previews no longer crash the
version popover.

**The suite got fast.** Parallel test execution (8 workers) plus the MRC source-resolution cap took
the full suite from 43 minutes serial to 88 seconds — the previously planned "fast local tier" became
unnecessary and was dropped.

## Deliberately not done

- **Per-page routing.** Classification is per document: one colour page cannot send a 20-page
  document to MRC, and a coloured stamp on one page of a near-bilevel document keeps the whole
  document on gs. Explicitly deferred — revisit if real documents keep leaving wins on the table.
- **JBIG2.** Better than CCITT G4 on bilevel scans, but it needs viewer-support verification and a
  native library. CCITT is universally supported and already delivers the large win.
- **Relaxing the OCR validation net.** The verbatim-prefix invariant is cheap and is the single
  strongest guarantee in the codebase; it stays permanently.

## What needs you

- **An Apple Developer ID.** Without it the DMG is ad-hoc signed: fine to run locally, not
  distributable. Users must strip the quarantine flag or right-click → Open. CI already has the
  signing and notarisation steps written, gated on `APPLE_*` secrets.
- **Delete the old installed copy.** The bundle identifier changed to `com.toolbox.app`; an older
  installed build under the previous identifier runs happily beside the new one and wins name-based
  launches. Remove it when installing the new DMG.

## Testing the DMG

Built locally, so it carries no quarantine flag and should open directly:

```sh
open dist/Toolbox.dmg
# drag Toolbox to Applications, then launch it
```

For a copy downloaded from a GitHub Release instead:

```sh
xattr -dr com.apple.quarantine /Applications/Toolbox.app
```

## Process notes worth keeping

- Two privacy leaks were introduced and caught before anything was pushed: a local absolute path,
  and separately one exposing the account name — both scrubbed from the entire branch history and
  independently verified. A semantic gate now guards the class, applied by intent rather than by the
  specific directory it names; it has since caught two further wording-level leaks in review.
- The UI defects existed because the original build was never driven, only launched. The same lesson
  recurred with MRC: green tests and engine-level validation missed defects that rendering the
  output and looking at it caught in minutes. Driving the packaged app and eyeballing real output is
  now part of "done" here.
- A QA session was nearly derailed by testing the wrong binary: the OS resolved the app's name to a
  stale build under the old bundle identifier. When results contradict the code, confirm *which*
  binary produced them before debugging the code.
