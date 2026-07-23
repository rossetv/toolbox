# Toolbox — build report

*What was built, what was verified first-hand, what is deliberately not done, and what needs you.*

Supersedes the earlier overnight report: that one predated the UI fixes, object-stream support, the
PDFWriter rewrite and Rung 2, and several of its statements are no longer true.

## Status

| Area | State |
|---|---|
| Compress — Rung 1 (Ghostscript) | shipping |
| Compress — Rung 2 (binarise + CCITT G4) | shipping |
| Compress — Rung 3 (MRC) | **not built** — deliberate, see below |
| OCR (Apple Vision + incremental update) | shipping, including object-stream PDFs |
| UI | rebuilt against the design mockup and driven end-to-end |
| Tests | **125, 0 failures** |
| Packaging | DMG builds, installs and compresses |
| Notarisation | **blocked on your Apple Developer ID** |

## Verified, not claimed

Everything here was run and read, not inferred:

- Full suite: **125 tests, 0 failures**.
- All six mechanical gates in `.claude/GATES.md` pass, including one that packages the DMG and
  asserts the **shipped bundle** really compresses.
- The packaged app, installed from the DMG to /Applications, compressed a real PDF by roughly
  **72.5%**, page count preserved, Ghostscript under the sandbox.
- The app was driven through its UI: files added via the picker, a batch compressed, results opened,
  Reveal in Finder confirmed to select the actual output file.
- Sandbox containment probed directly: Ghostscript launches, network egress is blocked, and reads
  outside the granted scope are denied.
- Gatekeeper behaviour checked (`spctl` rejects the unnotarised build; stripping quarantine clears it).

## What changed since the first report

**The UI was broken and is now fixed.** As first shipped, the app was effectively unusable: the
sidebar was invisible and no button did anything. Three independent defects:

1. Two `.fileImporter` modifiers were attached to the same view. On macOS they conflict and neither
   presents — so every route into the app silently did nothing. Replaced with `NSOpenPanel`.
2. The window could open smaller than its content minimum. SwiftUI's `.frame(minWidth:)` only clips,
   so the sidebar collapsed to zero width. Now enforced on the `NSWindow` itself.
3. `NavigationSplitView` laid the sidebar out a titlebar's height too high, hiding its first entries
   and drawing the rest over the traffic lights. Replaced with an explicit split.

**Rung 2 was added**, and it closes a real gap rather than a theoretical one. Ghostscript's mono
settings only apply to images that are *already* 1-bit, so a greyscale scan that merely looks
black-and-white is treated as a grey image — measured, one came out roughly **29% larger** through
Rung 1 and the app would report it as "already optimised". Rung 2 binarises first, then encodes
CCITT G4 via ImageIO and reassembles the page.

**Object streams are now supported**, so OCR no longer declines Acrobat-optimised PDFs. (Unit-tested; OCR
coverage across a mixed sample has not been re-measured since.)

**PDFWriter was rewritten** after an adversarial review: a byte-level tokeniser, correct handling of
literal strings and CRLF, bounded object scans, an integer-overflow guard, streaming I/O with a
per-job memory bound, and a cap on page rasters.

**Polish**: generated app icon, "Toolbox" throughout macOS, smaller default window, hand cursors
on controls, page counts, predicted-saving badges, and the mockup's progress and completion states.

## Deliberately not done

- **MRC (Rung 3).** This is where the large wins on *colour* scans would come from. It is a
  substantial subsystem and its value depends entirely on segmentation quality, which is an empirical
  question — the specification requires a spike before building it, and that spike has not produced a
  verdict. Building it on optimism would be the wrong call; shipping without it is explicitly allowed.
- **JBIG2.** Better than CCITT G4 on bilevel scans, but it needs viewer-support verification before it
  could be a default, and it requires a native library. CCITT is universally supported and already
  delivers the large win.
- **Relaxing the OCR validation net.** The writer has since been properly rewritten, so this is
  unblocked — but the verbatim-prefix invariant is cheap and is the single strongest guarantee in the
  codebase, so it should stay permanently regardless.

## What needs you

- **An Apple Developer ID.** Without it the DMG is ad-hoc signed: fine to run locally, not
  distributable. Users must strip the quarantine flag or right-click → Open. CI already has the
  signing and notarisation steps written, gated on `APPLE_*` secrets.

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
  and separately one exposing the account name — the latter in two shipping source files.
  Both were scrubbed from the entire branch history and independently verified. A semantic gate now
  guards the class, applied by intent rather than by the specific directory it names.
- The UI defects existed because the original build was never driven, only launched. Building,
  launching and "tests pass" did not catch a completely unusable interface; clicking it did.
- An abandoned jbig2enc/leptonica native-encoder experiment (Rung 2 ended up shipping on ImageIO's
  CCITT encoder instead, linking no native library) left a dead `.cpp` file in the compile sources
  and header/library search paths in `project.yml` pointing at a git-ignored tree. The project
  built and gated green only on the machine that happened to still have that tree — CI would have
  failed on the first push. No Swift code referenced any native symbol, so it was dead weight, now
  deleted. Verified by building and running the full suite with the tree moved aside.
