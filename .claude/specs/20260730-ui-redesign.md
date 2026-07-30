# Spec — Toolbox UI redesign (unified queue)

**Date:** 2026-07-30 · **Branch:** `feat/ui-redesign` · **Status:** draft, spec-gate pending
**Design authority:** Claude Design handoff, machine-local at `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/handoff/` — `README.md` (tokens, screens, copy, motion), `Toolbox Final.dc.html` (source of truth for any value the README omits), `renders/screen-*.png` (reference captures). The handoff's visual/copy/motion values are law; this spec is law for behaviour, and records every deliberate divergence.

## 1. Origin

The user redesigned the entire app in Claude Design ("Toolbox UI Redesign" project) and asked for a faithful implementation. The problem the redesign solves, in the user's terms: the two-tool sidebar makes a one-job app feel like two apps — you pick a tool before you have said what you want done to your files, history has no home, and recovery from a wrong choice is buried. The redesign makes the window one thing: a queue of PDFs plus verbs you tick (Compress, OCR — independently toggleable, one pass per file), with history in the empty state, everything else behind a `⋯` menu, quality priced in megabytes for the actual files, every produced version switchable until quit, and problems as rows rather than alerts.

## 2. Goal

Implement all 14 design screens (01 Empty, 02 Drag-over, 03 Ready, 04 Quality popover, 04b OCR popover, 04c Per-file settings, 05 Working, 06 Finished, 07 Versions, 08 Change quality, 09 Scan choice, 10 Problems, 11 Recent batches + update banner + About, 12 Dark) at high fidelity, in SwiftUI, on the existing engine/services/store layer, plus the new capabilities the design mandates: unified single-pass queue, per-file overrides, recent-batches history, scan-rebuild consent, save-destination chrome, update banner with full self-update, About sheet. Screens are cited by **name** throughout (the handoff uses two numbering schemes; headings above match `Toolbox Final.dc.html` section labels and `renders/`).

## 3. Non-goals (explicit)

- **Password unlock** (human decision, 2026-07-30): locked PDFs surface as problem rows with Skip / Remove only. The design's "Enter password…" button does NOT ship in this change. Follow-up work.
- **Sparkle / signed-update infrastructure**: rejected while the DMG is self-signed (human decision; see §6.10).
- **Localisation**: copy ships in English, hard-coded, as today.
- **New PDF tools** beyond the two verbs; the design's extensibility is structural only.
- **README.md edits**: the human ruled the existing claims remain true (update is user-initiated: "you always choose"). README is not touched. KB docs and `UpdateChecker` doc comments (Claude-owned) ARE updated to describe the new download path.

## 4. Human decisions (2026-07-30, binding)

| # | Decision | Why (user's terms) / rejected alternative |
|---|----------|-------------------------------------------|
| D1 | Update button performs **full self-update**, hand-rolled, mirroring `scripts/install.sh` end to end | User: DMG is self-signed "and will stay that way for a while"; updater must do "everything like `xattr -dr com.apple.quarantine …` and similar full installation" to the one-line installer. Rejected: open-release-page only (too weak for the designed button), Sparkle (dependency + appcast/key infrastructure for an unsigned channel it cannot strengthen). |
| D2 | Batch concurrency **stays P-core parallel** | User chose throughput over the design's single-active-file composition. Working screen adapts (§7 Working). Rejected: sequential one-file-at-a-time. |
| D3 | Password unlock **deferred** | Smaller LCW now; screen ships without its primary fix action, knowingly. |
| D4 | **DESIGN.md rewritten by Claude** from the handoff | User authorised; §8 covers citation re-anchoring. |
| D5 | Queue VM = **evolve `CompressViewModel`** | Keeps race-safe naming, retry, delivery invariants; rejected fresh VM (re-implements ~1,200 proven lines for no user-visible gain). |
| D6 | "See what changed" → GitHub release **tag page** via the validated `Release.pageURL` | User gave the tag-URL form explicitly; hand-built URLs rejected (they bypass `parseRelease`'s https+github.com pinning). |
| D7 | MRC auto-pick → **per-file consent sheet** (Scan choice screen), with "Rebuild scans from now on without asking" preference | Approved in the pre-spec summary; supersedes the silent D7 winner-pick from the MRC spec (documented reversal — see §5). |

## 5. Prior-art constraints

Three prior specs bind this work: `20260722-pdf-toolbox-v1.md`, `20260723-mrc-rung3.md`, `20260725-recompress-quality.md` (R1–R20). Constraints **kept** (adapted to the unified VM, never dropped): the naming/never-overwrite/atomic-delivery contracts and output validation (v1 §5.4); the seatbelt sandbox scope per gs invocation — files added mid-run get the same per-job scoping (v1 §11.4); honest progress, never fabricated (v1 §8); recompress R-rules R1–R8, R10–R18, R20 re-derived onto per-row effective presets (R18's cache lifecycle — launch sweep, quit wipe, discard on clear/removal — is what §7's consent-purge copy relies on); MRC delivery invariants (never-larger-than-input, OutputValidator, original untouched); the verbatim-prefix incremental-update invariant — now **per variant**: each delivered variant carries its own appended layer, so every file independently satisfies it; PDFWriter's dropped-annotation reporting obligation (v1 §4) — the Finished row's meta notes dropped annotations when a rebuild sheds them.

**Deliberate reversals** (each carries its authority; all inside the human-approved redesign):

| Prior rule | Reversal | Authority |
|---|---|---|
| v1 §2/§6: combined compress+OCR pass deferred to v2 | This change IS that pass | Fulfilled deferral — the redesign's core |
| Recompress D5: batch-level control only, per-row pickers deferred (pre-authorised as "expected first follow-up") | Per-file overrides ship | Fulfilled deferral; `testLaterBatchDoesNotRewriteAFinishedRowsPreset` and R16's provenance rule re-derived per-row |
| Recompress R9: +Add/drop target disabled during a run | Drag-during-run everywhere | Design mandate ("including during a run"); enabled by add-time reservation (§6.5) |
| Recompress R19: OCR gains no recompress behaviour | Re-runs re-apply OCR | Consequence of the searchability invariant (§6.4) |
| MRC R7 asymmetry: hybrid-lost-the-gate is discarded | Both scan variants retained whenever a valid hybrid AND a valid gs output exist; D7's byte-size gate now picks only the **provisional** shipped file; the consent sheet's choice is an instant version switch | D7-consent decision (human, 2026-07-30) — consent is about the *look* of the page, not only bytes |
| v1 §7 deviation 2: "Saved this month" widget cut for lack of storage/reset semantics; MRC R15's narrow no-persisted-state exception | History store ships with defined storage, retention and clear semantics (§6.9) | Design mandate; §6.9 supplies exactly what v1 found missing |
| Recompress mockup + MRC D8 as visual contracts | The handoff supersedes all prior visual contracts | The redesign's purpose. D8's *rejected alternatives stay rejected* — no in-app A/B comparator; comparison remains "open both in Preview" |

**Version-cap ruling** (R14/R15 collision): parked versions stay capped at two (the consent-retained loser occupies the runner-up slot; one previous-quality park), plus the shipped file and the untouched original (referenced in place, never parked). The versions popover is the design's radio list — it supersedes R15's card geometry and handles up to four rows.

## 6. Architecture

### 6.1 Unified queue view model

`CompressViewModel` becomes `QueueViewModel` (file renamed with it; `Compress/` directory keeps engine files, VM moves to a new `Sources/Toolbox/Queue/` only if the plan finds that cleaner — default is rename in place). It absorbs:

- **Verb set**: `@Published var compressOn: Bool = true`, `ocrOn: Bool = false` (batch-level), plus `OCROptions` (language, accuracy) and the existing `preset`. At least one verb on ⇒ Start enabled; zero verbs ⇒ Start disabled (chip UI enforces).
- **Per-file overrides** (Per-file settings screen): optional per-row `preset`, `rebuildScan` (MRC opt-out/in), `ocr` override. Stored as a sparse `[ToolJob.ID: RowOverride]`. Every preset-keyed structure gains row scope: arming/`recompressState` compares against the row's effective preset; `futileAttempts` keys by `(id, effectivePreset, verbSet)`.
- **OCR integration**: `OCRViewModel` and `OCRView` are deleted; `OCREngine`, `VisionOCR`, `OCROptions` stay. The queue's job body runs compress (when on) then OCR (when on) as one `ToolJob` with one row.
- `CompressView` is deleted; new view files implement the design's screens on `DesignSystem` components.

### 6.2 Single pass, verb order

Per file: **compress first, then OCR** — Rungs 2/3 rasterise pages, which would destroy a pre-existing text layer; OCR-ing afterwards also means the text layer lands on the file that ships. This order is an engine fact, not a preference.

### 6.3 Compound outcomes

`JobOutcome`'s flat exclusive enum cannot express "Rebuilt and searchable · 78% smaller". It becomes a **verb-keyed per-file result** carried by the existing `Shared/ToolQueue.JobResult` (which already holds outcome + outputURL + alternateURL + mrcReport — extended, not duplicated; no second result type): `compress: CompressOutcome?` × `ocr: OCROutcome?`, where `CompressOutcome` covers compressed/noGain/skipped-problem plus a **runner-up descriptor** (engine variant kind `.plain`/`.original`, bytes, searchable flag) that exists whenever a second valid variant is retained — **regardless of which variant won the gate** (the descriptor, not the old `compressedHeavy` case, is what triggers the consent sheet and the versions capsule; keying on `compressedHeavy` would silently reinstate the R7 asymmetry §5 removes). `OCROutcome` covers added(pages)/alreadySearchable/tooFaint/failed. **Size-rule precedence**: never-larger-than-input applies to the *compress artefact* — a compress variant ≥ input is withheld (not delivered, not offered on a card); the OCR append may then grow the net file past the compressed size and even past the input (it adds content the user asked for) — always shown honestly. Consequences, all in scope:

- Every consumer switches: `ingestCompletedJobs`, `commit`, `recompressState`, `ToolQueue.process`, the smoke's outcome switch, history rows, row meta copy.
- **A combined pass can net larger** (modest compression + a large text layer). New row state: sizes shown honestly ("12.4 MB → 13.1 MB"), meta explains ("Searchable now · grew slightly"). The design has no "grew" state; this is a specified divergence, honesty over fidelity.
- OCR-only rows show "no change" grey sizes (the design's Recent-batches sheet already has this state; the live footer adopts it too: an OCR-only batch's footer says files made searchable, never "0 MB saved").

### 6.4 OCR recognises from the original; the layer is appended to every variant

**The fatal this kills**: every parked variant (runner-up, previous-quality, consent-sheet "photographs") is written by the compress stage, before OCR — so version switch, quality re-run, change-quality promote, and consent "Keep photographs" would each hand over a file whose row says "searchable" but whose bytes carry no text layer. Misrepresenting the user's data is a ship-blocker by this repo's own standard.

**The shape**: when OCR is on, recognition runs ONCE per file against the **original** pages (better input than an MRC-flattened raster — exactly what the Accurate mode promises for faint/small print), producing per-page recognised runs + `PageGeometry`. `PDFWriter.appendTextLayer(to:output:pageText:geometry:)` then appends the layer to **each variant the job delivers**: the winner and, when present, the runner-up. MRC/bilevel composers emit pages with origin (0,0), no `/Rotate`, MediaBox = raster size (their own doc contract), so appending to those variants re-projects box coordinates from original geometry by the uniform scale — well-defined; Rung-1 output keeps original geometry (append is direct).

- Quality re-runs / change-quality regeneration: the regenerated file gets the layer re-applied. Recognition results are NOT cached across runs (memory: recognised runs are hundreds of MB for large docs); the re-run re-recognises with its normal progress UI.
- Any variant that cannot carry the layer (append failure) is **labelled honestly** — "not searchable" in the versions popover subtitle — never silently claimed searchable.
- **The untouched original is never appended to.** When the runner-up slot holds the `.original` variant (gs bloated; nothing legitimate to offer), the original-untouched invariant wins: no layer, popover row labelled "not searchable" whenever OCR ran, and switching to Original downgrades the row's searchability label honestly. Same rule for the versions popover's always-present Original reference row.
- The incremental-update invariant (original bytes = verbatim prefix; fail-loud validation) continues to apply to every append.

### 6.5 Naming and reservation — reserve at add time

The design requires drag-and-drop to work on every screen **including during a run**; today `CompressViewModel.add` and `ToolQueue.add`/`run` guard against it because output names are reserved in a serial pass at run start (race rationale documented in code). Resolution: **names are reserved when a file is added**, not at run start. The reservation ledger becomes queue-lifetime; a removed row releases its reservations. Per job the ledger reserves every name the row's *effective* verb set can produce: the delivered output and the alternate (runner-up) where a rebuild is possible — nothing else (the OCR leg needs no third name: it writes to a temp inside the job workspace and replaces onto the delivery path with `FileManager.replaceItemAt` semantics; `OCREngine`'s move-onto-existing throw is handled by the queue layer, not weakened in the engine). **Delivered names, pinned**: any run that includes Compress delivers `<name>-compressed.pdf`; an OCR-only run delivers `<name>-ocr.pdf` — both v1 conventions, and the Finished screen's "saved as Annual-Report-2025-compressed.pdf" copy stays true. `VersionStore.shipped.url` always names the single delivered file. **Ledger invalidation**: reservations recompute (release + re-reserve) whenever a mutable input changes while the queue is idle — save destination, batch verb toggles, per-row overrides (a `rebuildScan` change adds/removes the alternate name; an `ocr`/verb change can switch the suffix), and a "Find it…" rebind. Once a run starts, destination/verb/override settings **lock for that run's jobs**; files added mid-run reserve at add against the locked settings (the R11 pin-to-existing-result-path rule continues to govern recompress re-runs). **Cancel between legs**: a file whose compress leg delivered but whose OCR leg was cancelled is **kept and banked, honestly labelled** ("Compressed · not searchable — cancelled before reading") — the compress delivery was atomic and complete; "no partial output" binds within a leg, never across legs. Every leg boundary carries its own cancellation check (the concurrency-retrofit lesson), including between the engine's return and the commit.

### 6.6 Add-time inspection

At add: page count, first-page thumbnail (existing `PDFThumbnail`), a text-layer sample (`PDFService.pageHasText`), content classification (from the estimator's analysis), and open-failure detection (locked / unreadable / missing). Produces the Ready screen's meta line ("48 pages, mostly photographs" / "32 pages, no text layer yet" / "12 pages, text and vectors") and surfaces problem rows **before** the run (locked file appears immediately as "Needs a password to open" with Skip/Remove — no password entry, D3). `OpenGuard`'s run-time inspection stays as the second net (files can move/lock between add and run — the Problems screen covers both moments).

### 6.7 Estimator honesty

The design prices presets in MB for the actual queue (popover totals, per-row predictions, footer sum). Today `CompressEstimator.predict` caps `.scanColour`/`.balanced` at 45% reduction while the MRC path really delivers ~78% — the design's own numbers (18.7 → 4.9 MB) are unreachable. In scope: **calibrate the MRC path into the estimator** (a `.scanColour` document on a preset where MRC runs predicts from MRC-class reduction, tempered by `payloadRatio`; measured constants derived during implementation against the repo's synthetic fixtures + the private corpus, recorded in the plan). Rows show an em-dash until their async estimate lands (analysis is time-boxed at 0.5 s and queued; the design's instant numbers are mock data). `isFallback` estimates display with "about" phrasing — already the design's wording — and never a false precision.

### 6.8 Concurrency

Batch width stays `SystemInfo.performanceCoreCount` (D2). Inside a job, the OCR leg acquires a **width-2 semaphore** (the memory bound `OCRViewModel` pins today: in-flight 300-DPI rasters + accumulated recognised runs are already hundreds of MB at width 2). The Working screen renders any number of active rows; the footer copy becomes: **"Toolbox works several files at once on your Mac's fastest cores."** (truthful replacement for the design's "one core at a time" line — D2's recorded copy divergence). Per-row ETA and the header "% · about Ns left" derive from a new lightweight progress aggregator (fractions already reported by both engines; ETA = smoothed rate over completed fraction, clamped to "about" phrasing; never shown before 10% of a leg has elapsed). Compress-leg active meta shows the leg name ("Compressing…" / "Rebuilding scan…" per rung), OCR leg shows "Reading page N of M" (fraction × page count — the engine reports per-page progress).

### 6.9 Recent-batches history

New `HistoryStore` (Application Support/`Toolbox/history.json`, schema-versioned envelope `{version: 1, batches: […], lifetimeSavedBytes: Int}`). Never placed under the runner-up cache root (that tree is purged at quit). Each batch: date, folder display name + URL, file count, preset, verb flags, per-batch savings, outcome flags (partial/problem/**cancelled** — a cancelled batch with at least one banked file records an entry so the strip/sheet never lose delivered work; a cancelled batch with nothing banked records nothing). Retention: newest 200 batches — months of heavy use at trivial size, a hard bound against unbounded growth. **"Clear list" empties `batches` only; `lifetimeSavedBytes` survives** — the empty-state copy reads "saved since you installed Toolbox" and the sheet promises "Clearing it doesn't delete any files"; both stay true. Feeds: empty-state strip (two most recent, hidden when empty), Recent-batches sheet (TODAY/YESTERDAY/date groups), "1.4 GB saved" figures. Local-only data on a "nothing leaves this Mac" app — no paths beyond what the user's own batches name.

### 6.10 Self-updater

Trust model, stated plainly (D1): the DMG is self-signed; there is **no code-signature verification possible**. The updater's integrity chain is exactly `install.sh`'s: HTTPS pinned to `api.github.com` / `github.com` (redirect-hopped hosts refused), the release's published `.dmg.sha256` checksum verified before any use. A compromised GitHub account or release channel = arbitrary code execution — accepted by the human, recorded in DECISIONS.md as a posture reversal (`UpdateChecker` doc comment + KB updated; README untouched per §3), revisit when signing lands.

Flow (mirrors `install.sh`'s integrity steps, with in-app-safe replacements where a shell idiom does not transplant): download DMG + `.sha256` → verify checksum → `hdiutil attach -nobrowse -plist` (mount point parsed, never assumed — the packaged-app gate's own lesson) → validate payload contains `Toolbox.app` and its `Info.plist` version equals the release tag → determine destination: the **running bundle's parent** when it is a user-writable `…/Applications` dir (`/Applications` or `~/Applications`); any other location (translocated, DMG, Downloads, dev build dir) → **degrade**: open the release page instead, with the banner explaining why → stage-copy via `ditto` to a temp sibling **on the destination volume** → conditional quarantine strip **on the staged copy, before any swap** (only when `spctl -a -t exec` rejects it, as `install.sh`; a failed strip aborts here — the current install is untouched) → **aside-swap, never rm-then-move**: rename the current bundle to a temp sibling (atomic, same volume), rename the staged bundle into place, delete the aside only after the rename succeeds; if the second rename fails, rename the aside back; if that restore rename itself fails, the aside is **never deleted** and the error line names its path — every failure leg ends with a working install on disk, at the install path or, in that last resort, at the named aside path → detach (best-effort, as `install.sh` — a busy volume never fails a completed install) → relaunch via a **detached helper process** that waits for this PID to exit and then opens the new bundle (plain `open`-then-terminate activates the still-running instance and quits it — the classic no-op; §11 verifies the relaunch empirically). **The Update button is disabled while a run is in flight** ("after the current batch finishes") — the swap would pull the bundled gs out from under active jobs (`GhostscriptRunner` resolves gs from `Bundle.main` per invocation). UI: banner button shows progress states (Downloading… / Verifying… / Installing…); failure returns the banner to "Update" with a plain error line and the release-page link.

### 6.11 Deletions

`App/SidebarView.swift` deleted. `App/Tool.swift`: the enum's tool-switching role dies; keep only what the smoke/tests still need (plan decides: likely full deletion with smoke keying on the engine directly — the smoke constructs `CompressEngine` directly today and survives regardless). `Compress/CompressView.swift`, `OCR/OCRView.swift`, `OCR/OCRViewModel.swift` deleted. `RootView` becomes the single-pane shell hosting the queue UI; `WindowConfigurator` re-tuned (900×640 min). The `⋯` menu: Recent batches…, Where files are saved…, About Toolbox. The app menu gains About (same sheet).

## 7. Screens — behaviour and divergences

Visual truth for each screen = handoff README §Screens + `Toolbox Final.dc.html` + `renders/`. This section specifies only behaviour bindings and the deliberate divergences.

- **Empty**: icon parallax via `onContinuousHover` + `rotation3DEffect` (Reduce Motion: static). Choose Files… → existing `FilePicker`. History strip from `HistoryStore` (§6.9), hidden when empty. "Open folder" reveals the batch folder in Finder.
- **Drag-over**: fan count mirrors the drag's item count (1/2/3/3+N badge). All screens accept drops, including during a run (§6.5).
- **Ready**: rows from add-time inspection (§6.6); hover gear opens Per-file settings; `+ Add`/`⊗ Clear` links; save-destination control is the existing `outputFolder`/`FilePicker.chooseFolder()` logic re-skinned ("Saving beside the originals ⌄" / folder name when overridden). Footer sums current sizes → estimates; Start disabled with zero verbs or zero healthy rows.
- **Quality popover**: three presets with live batch totals from the estimator (§6.7); RECOMMENDED badge on Balanced; queue dims 40% behind.
- **OCR popover**: language dropdown (English default + `OCROptions` curated list), Fast/Accurate segmented (Accurate default), captions per design. Maps to `OCROptions.Accuracy` and `languages` (explicit selection; empty-auto remains the engine default when the user never opens the popover).
- **Per-file settings**: overrides per §6.1; "Rebuild the scan" toggle is the per-file MRC opt-out/in — **new engine parameter** (today `wantsMRC` is derived internally; the engine gains an override input, default unchanged). **Toggle domain, pinned**: it binds only on `.scanColour`-classified rows (elsewhere it is hidden or disabled with a caption); opt-in never overrides classification eligibility — the MRC complex-page safety rule that protects text/vector content from rasterisation stands (MRC R2 kept); at High quality the toggle is disabled with an explanatory caption (MRC D3 kept: never MRC at `maximumQuality`). Opt-out is always available. Footer estimate reflects overrides; "Match the batch" clears them. Overridden row's meta becomes accent "Its own settings"; batch footer notes the divergence.
- **Working**: multiple active rows legal (D2). Status column: finished check / active filling ring / queued dashed circle, one 16 px slot. Active row shimmer per design; ETA rules §6.8. Cancel = existing cancel semantics (finished files are already banked — they were delivered as they completed).
- **Finished**: header numbers **computed from rows** (sum of befores/afters of compressed rows; "One is now searchable" from OCR outcomes). Row click opens the file; versions capsule per row when `VersionStore` holds versions. Show in Finder / Change quality / Add More per design.
- **Versions popover**: existing `VersionStore` slots + honest searchability subtitles (§6.4). "Compare versions…" opens both in Preview (existing pattern). Instant swap unchanged.
- **Change quality**: three cards priced from current rows (§6.7); per-row mechanism lines ("Already on disk — swapped in immediately" when the variant exists in `VersionStore`/`RunnerUpStore`; "Redone from the original at N DPI · about Ns"); works both directions. **Duration source, pinned** (honest-progress rule forbids fabrication): the "about Ns" figure derives from the row's own completed run — measured per-page rate × page count, "about"-clamped; a row with no measured run shows the mechanism line without a duration. "Choose which files…" scopes the re-run to a checked subset (new, per design). Re-runs re-apply OCR (§6.4).
- **Scan choice (consent)**: sheets surface **as each file's delivery completes, mid-run** (banked-immediately extended), one at a time, FIFO across files; shown whenever BOTH a valid hybrid and a valid gs output exist for a rebuilt scan — including when the hybrid lost the size gate (R7 asymmetry removed, §5). A variant that is ≥ the input is withheld entirely (§6.3's size rule), so a card never advertises a regression. The D7 gate winner ships **provisionally** (delivery stays atomic and banked-immediately); the consent choice is an instant version switch between files already on disk, so "Nothing is decided yet" is honest. No hybrid built/verified → no sheet. If a variant card's honest numbers undercut the design's copy (e.g. the rebuilt file is *larger*), the card states the truth — recommendation badge stays, percentages never lie. "Rebuild scans from now on without asking" preference (UserDefaults) suppresses future sheets and keeps the **rebuilt** variant whenever it exists and validates (that is the toggle's promise; the size gate then only orders the provisional state while the sheet-less delivery completes); the versions capsule remains the undo. "Open both in Preview" side-by-side. The un-kept variant follows the existing quit-purge lifecycle (`RunnerUpStore.removeAllOnDisk` at terminate; force-quit defers to next-launch sweep — copy says "when you quit", reality is "at quit, or next launch after a crash": accepted).
- **Problems**: add-time and run-time problems as tinted rows (danger/warn), fix affordances inline. This change ships **Skip / Remove / Find it…** ("Find it…" = re-pick a moved file via open panel, rebinding the row); "Enter password…" does NOT ship (D3). Degraded outcomes ("Too faint to read — compressed, but not searchable") from the OCR outcome. Footer: "Files that failed were not touched at all."
- **Recent batches sheet / Update banner / About**: per design; banner appears when `UpdateChecker` finds a newer version, slides per motion spec, × dismiss persists per-version (`bannerDismissed` keyed by version). Update button → §6.10; "See what changed" → `Release.pageURL` (D6). About: version from bundle, links Source Code / Licence / Contact me, AGPL notice.
- **Dark**: token swaps per handoff table; verified in both appearances during visual verification.

## 8. Design system and DESIGN.md

`Theme.swift` becomes the single home of the handoff's token table (light + dark), typography scale, radii, spacing, shadows, and motion constants (standard curve ≈ `.spring(response: 0.35, dampingFraction: 0.85)`; named durations). Components rebuilt/extended in `Components.swift`: FileRow (new anatomy), verb chips, popover chrome, option cards, status ring/check/dashed states, progress capsule bar, sheet chrome, banner. System semantic colours used where the handoff maps them (accent → `controlAccentColor`, success → system green, etc.); hex used only where no system equivalent is named. SF Symbols replace the HTML's hand-drawn glyphs per the handoff's mapping. All numbers `.monospacedDigit()`.

**DESIGN.md rewrite (D4)**: rewritten from the handoff as the app's visual law. Constraints: **every** in-code reference to DESIGN.md — `§N` forms (14) and prose mentions (41 total) — is re-anchored or re-worded against the new document in the same change (the sweep greps for `DESIGN.md`, not only the `§N` pattern; zero stale references at gate time); the **Focus (Accessibility) row is preserved** — the stray-focus-ring standing invariant (memory 2026-07-25) anchors to it; `.clearsClickFocus()` and the first-responder-clear behaviour remain mandatory on every `.plain`-styled control the redesign adds.

## 9. Accessibility

- Every hover-only affordance gets a non-hover path: gear → row context menu + visible on keyboard focus; row states focusable; `Return` opens a focused row; versions capsule reachable by keyboard.
- Verb chips are compound controls: toggle action + "open options" action, separately labelled for VoiceOver.
- Status column states carry VoiceOver labels (finished/working/waiting + detail).
- Reduce Motion: parallax, drag fan float, shimmer, sweep, breathing dots all gate on `accessibilityReduceMotion` (static or cross-fade equivalents).
- Focus rings per DESIGN.md accessibility row; popover close paths re-tested against the stray-ring invariant (its regression test stays green).

## 10. State management (summary)

Queue rows (add-time analysis, effective settings, live progress, result, problems), batch verb set + options + preset, per-file overrides, save destination, version inventory (`VersionStore`/`RunnerUpStore`), pending consent decisions, history (`HistoryStore`), update availability + per-version banner dismissal, "rebuild without asking" preference. Batch summary figures are always **computed from rows** — never hard-coded (handoff's own rule).

## 11. Testing & verification

- **Unit/integration**: the recompress safety net (R-rules) is **re-derived, not summarised** against the evolved VM — every existing test enumerated with a stated outcome (adapt / superseded-by / new). New tests: compound outcomes (incl. "grew"), OCR-append-to-variants (every layer-carrying switch path delivers a searchable file; the `.original` switch path asserts no-append plus the honest downgrade label, §6.4; append-failure labels honestly), add-time reservation under drag-during-run (width > 1 double re-derived per the concurrency lessons), estimator MRC calibration bounds, HistoryStore round-trip + clear-preserves-lifetime, updater flow against a local fixture server (checksum mismatch, mount failure, non-Applications install → degrade path, **every aside-swap failure leg ends with a working install**, quarantine-strip failure aborts pre-swap; never against live GitHub in tests), leg-boundary cancellation (compress→OCR boundary, engine-return→commit boundary; kept-and-banked disposition asserted).
- **Smoke**: `TOOLBOX_SMOKE=compress` survives (engine-level); extended assertion for the compound outcome shape.
- **Gates**: all `GATES.md` gates green, incl. `tests` (mandated-by-human) and `packaged-app-compresses`.
- **Visual**: build the app, drive it with computer-use, capture **every design state** (14 screens, light + dark where the design shows both), compare side-by-side against `renders/screen-*.png`; iterate until they match; archive comparison shots in the run's ledger dir. This is a user-mandated done-criterion.
- **Functional**: run every flow against the user's private test corpus (path never referenced in the repo — standing rule): compress-only, OCR-only, both, per-file overrides, versions switch (searchability preserved), change quality both directions, scan consent both choices, problem rows (locked, moved), history accrual, update banner (fixture server). **Relaunch, empirically** (a dev build dir hits the degrade path by design, so this needs deliberate setup): install a build into `~/Applications`, run one real update against the fixture server, assert the old instance exits and the relaunched app is the new version. Outputs inspected first-hand: text layer present and selectable, compressed files open and render, sizes as reported.

## 12. Risks & fallbacks

- **Updater edge terrain** (translocation, non-standard installs): mitigated by the degrade-to-release-page rule (§6.10); the swap path only ever runs on a writable Applications install.
- **Estimator calibration misses** (predictions still off for odd corpora): "about" phrasing everywhere; Finished screen shows truth; no promise of exactness.
- **MRC geometry re-projection** for OCR append proves fiddlier than the uniform-scale contract suggests: fallback is OCR-append to Rung-1-shaped variants only + honest "not searchable" labels on composed variants — the fatal stays dead (honesty rule), only coverage narrows.
- **Evolved-VM regression risk**: the R-net re-derivation is the guard; any invariant that cannot be preserved is a stop-red spec escape, not a silent drop.
- **Design/behaviour conflicts discovered mid-build** (an approved-spec contradiction): stop red per LCW escape rules.

## 13. Acceptance criteria

1. All 14 screens implemented; visual comparison vs `renders/` passes inspection (layout, tokens, copy, motion character), light + dark.
2. Sidebar and old tool views gone; every listed new capability works end to end.
3. No version-switch path can deliver a file whose searchability label is false.
4. Gates green; R-net re-derived; smoke passes; no `DESIGN.md §` citation left stale.
5. Functional pass over the private corpus per §11.
6. PR references this spec path.

## 14. Verification evidence (first-hand, 2026-07-30)

- `CompressEstimator.baseReduction[.scanColour][.balanced] == 0.45` (cap confirmed) — the design's 74–78% scan predictions are unreachable today.
- `JobOutcome` is a flat exclusive enum (cases read directly) — compound results unrepresentable.
- `OCREngine` throws `.sameInputOutput` and delivers via `moveItem` (throws onto existing path) — §6.5's replace semantics required.
- `CompressEngine`: `wantsMRC` derived internally (`classification == .scanColour && preset != .maximumQuality`); `alternateOutput` written only on the MRC branch — per-file rebuild toggle needs a new engine input. (In *today's* code a second variant exists only for `compressedHeavy`; §6.3's runner-up descriptor deliberately widens that — the descriptor, never the old case, keys the consent sheet.)
- `CompressViewModel.add`/`ToolQueue.add|run` guard against `isRunning`/`runTask != nil` — drag-during-run requires §6.5's reservation move.
- `OCRViewModel.run` pins `maxConcurrent: 2` with a memory rationale — §6.8's semaphore inherits it.
- `applicationWillTerminate → RunnerUpStore.removeAllOnDisk()` + `sweepStale()` at VM init — consent-sheet purge copy is backed.
- `FilePicker.chooseFolder()` + `outputFolder` + UI row already exist — save-destination work is chrome only.
- `UpdateChecker.parseRelease` pins `https` + `github.com`; `Release.pageURL` exists (D6's guard).
- `install.sh` read end to end — §6.10's flow mirrors it (incl. `.sha256` verification, mount-point parsing, conditional quarantine strip, `/Applications` → `~/Applications` fallback).
- Released DMG is unsigned/unnotarised (user-confirmed: self-signed and staying so).

---

## Gate rounds

- **R2 (incremental, Fable 5): NO-SHIP** — F1, F3–F11, m1–m8 confirmed fixed; F2 still open (claimed §11 relaunch verification didn't exist → now added with the `~/Applications` setup requirement); new m9 (§11's "every switch path searchable" contradicted §6.4's `.original` carve-out → reworded), m10 (restore-rename failure disposition → aside never deleted, path named). Lesson-candidates: a "§X verifies this" cross-reference must land in §X in the same edit; after carving an exception, grep testing text for absolute quantifiers over the same surface; recovery legs are legs — spec their failures too.
- **R1 (full read, Fable 5): NO-SHIP** — F1 critical (rm-then-move swap could destroy the install → aside-swap specified), F2–F11 major (relaunch no-op hazard → detached helper; update-during-run → button gated on idle; `.original` never appended to; runner-up descriptor replaces `compressedHeavy` keying; delivered suffixes pinned; ledger invalidation rules; leg-boundary cancel disposition; rebuild-toggle domain pinned to MRC R2/D3; duration source pinned; size-rule precedence), m1–m8 minor (all fixed: R18 kept-list, lifetime counter survives Clear, retention rationale, `JobResult` absorbed not duplicated, citation sweep widened, consent timing pinned mid-run FIFO, cancelled-batch history entry, detach best-effort + pre-swap strip). Lesson-candidates: shell idioms don't transplant into self-updaters; re-derive triggers when an exclusive enum gains siblings; "kept, adapted" must state the adaptation per surface; reservation designs need invalidation rules; multi-leg jobs re-open partial-output/cancel definitions per boundary.
