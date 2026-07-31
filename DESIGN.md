# Toolbox — Design System

Toolbox's visual law: colours, type, spacing, radii, shadows, motion, the component
inventory, the twelve-screen structure, and the copy register. Rewritten 2026-07-30 from
the "Toolbox UI Redesign" handoff (human decision D4) as the single-window unified-queue
app — no sidebar, one queue of PDFs plus two independently toggleable verbs (Compress,
OCR) applied in one pass. The handoff's colours, type sizes, spacing, radii, copy and
motion timings are matched exactly except where §11 records a deliberate divergence.
Behavioural law lives in `.claude/specs/20260730-ui-redesign.md`; this document is
self-contained for the visual language and does not depend on anything outside the repo.

Code identifiers are canonical throughout — `Theme.Colors.background`, not the design
source's raw `bg`. Every token below is named exactly as it appears in
`Sources/Toolbox/DesignSystem/Theme.swift`.

## Section Index

| § | Section |
|---|---|
| 1 | Visual Language and Principles |
| 2 | Colour Tokens |
| 3 | Typography |
| 4 | Components |
| 5 | Layout, Spacing and Radii |
| 6 | Depth, Elevation and Focus (Accessibility) |
| 7 | Do's and Don'ts |
| 8 | Motion |
| 9 | Screens |
| 10 | Copy Register |
| 11 | Divergences from the Handoff |

## 1. Visual Language and Principles

Toolbox is one window: a queue of PDFs and the verbs you tick. Five structural rules
carry every screen:

1. **No sidebar.** The window is a single content pane, 900×640 minimum.
2. **One queue, two verbs.** Compress and OCR are toggle chips above the file list. Both
   can be on; a run applies both, per file, in one pass.
3. **History is not a page.** Recent batches surface at the foot of the empty state and
   as a sheet from the `⋯` menu.
4. **Versions, not regret.** Every produced variant stays on disk until quit and can be
   swapped instantly.
5. **Problems are rows, not alerts.** A locked, missing or unreadable file shows inline
   with its fix beside it; the rest of the batch completes.

Visual character: a light neutral canvas (`background`/`surface`) carries **one**
chromatic accent (system blue) reserved exclusively for interactive elements — semantic
colours (`link`, `success`, `warn`, `danger`) communicate state, they are not a second
accent. Surfaces are flat: no gradients, shadow used only where §6 names it, borders rare
and only as recorded. The system font (SF Pro / San Francisco) is used at its own optical
size automatically — every role in §3 sits at or below 22pt, well inside the Text optical
range, so nothing in this app ever needs the Display cut. Every number on screen —
sizes, percentages, counts, timings — is `.monospacedDigit()`.

## 2. Colour Tokens

Every named token is a `Theme.Colors` case. Light/dark pairs resolve automatically via
`Color(light:dark:)`, which AppKit re-evaluates on every appearance change.

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#F5F5F7` | `#1C1C1E` | App canvas, row hover fill, recessed "grouped" fill |
| `surface` | `#FFFFFF` | `#242426` | Window content surface: detail pane, cards, popovers, sheets |
| `text` | `#1D1D1F` | white | Primary text |
| `textSecondary` | black 80% | white 80% | Subtitles, secondary text |
| `textTertiary` | black 48% | white 48% | Meta lines, captions, disabled/muted state |
| `accent` | `#0071E3` | `#0A84FF` | The single chromatic accent — interactive elements only |
| `link` | `#0066CC` | `#2997FF` | Inline text links — distinct from `accent` |
| `success` | `#34C759` | `#32D74B` | Completion, savings figures |
| `warn` | `#FF9F0A` (one constant, both appearances) | | Partial results, needs-attention |
| `danger` | `#D70015` | `#FF453A` | Password/error rows |
| `stroke` | black 16.8% | white 16.8% | Control border / inset ring |
| `sep` | black 12% | white 12% | 1px section separators |
| `hairline` | black 9.6% | white 9.6% | Inset hairlines, fainter than `sep` |
| `fill` | `#1D1D1F` 6% | white 10% (deliberately asymmetric — not a mirrored pair) | Quiet control fill: hover backgrounds, capsule chips at rest |
| `track` | `#1D1D1F` 12% | white 12% | Progress-bar track |
| `documentBadge` | `#FF3B30` (single constant; no handoff counterpart) | | PDF file-type iconography only — outside the single-accent rule, used solely by `PDFThumbnail`'s label band |

Component-local, not `Theme` tokens: `SecondaryButton`'s dark fill (`#3A3A3C`) is
deliberately **not** `surface`'s dark value (`#242426`) — the design wants a visibly
lighter grey for secondary buttons than the window surface behind them.

## 3. Typography

Every role is a `Theme.Typography` case, applied via `Text.themeFont(_:)` (font + tracking
together). All sizes in points; tracking in points (negative = tighter).

| Role | Size / Weight | Tracking | Use |
|---|---|---|---|
| `windowHeadline` | 22 / semibold | −0.3 | "3 files", "32.6 MB lighter" |
| `sheetTitle` | 17 / semibold | −0.2 | "Recent batches", "Different quality for these 3 files" |
| `rowName` | 15 / semibold | −0.2 | Queue row filename |
| `bodyStrong` | 13 / semibold | −0.2 | "3 files in Contracts", footer totals |
| `body13` | 13 / regular | −0.2 | Plain 13pt figures, arrow-separated sizes |
| `meta` | 12 / regular | −0.2 | Row descriptive meta line ("48 pages, mostly photographs") |
| `caption` | 11.5 / regular | −0.2 | Popover/radio-row subtitles, batch-card timestamps |
| `sectionLabel` | 11 / semibold, uppercase | +0.4 | "QUALITY", "TODAY" group labels |
| `link` | 14 / regular | −0.224 | Inline text links — **see §11**, the handoff pins 13pt |
| `captionBold` | 14 / semibold | −0.224 | Pre-redesign emphasised caption role, unchanged |
| `micro` | 12 / regular | −0.12 | Fine print (pre-redesign role, unchanged) |
| `microBold` | 12 / semibold | −0.12 | Bold fine print (pre-redesign role, unchanged) |
| `nano` | 10 / regular | −0.08 | Legal text, smallest size (pre-redesign role, unchanged) |

Unlabelled small text in the handoff inherits its document-wide −0.2 default; `bodyStrong`,
`body13`, `meta`, `rowName` and `sheetTitle` all carry that value for this reason, not by
coincidence. `sectionLabel`'s positive tracking is the one deliberate exception — uppercase
micro-labels need the air back.

## 4. Components

### 4.1 Retained (Phase 0)

Four components pre-date the redesign and are restyled, not replaced — their names and
call sites are unchanged.

- **`PrimaryButton`** — the filled accent CTA: white 14/semibold label, flat `accent`
  fill (no gradient, no glow — §7), `control` (8) radius. "Choose Files…", "Start",
  "Update", "Add More".
- **`LinkButton`** — a borderless `link`-blue text action: "+ Add", "Clear", "Change…",
  "Match the batch", "See what changed". See §11 for its recorded size divergence.
- **`StatPill`** — a small `pill`-radius badge for a short stat. Tones: success / neutral
  / accent.
- **`PDFThumbnail`** — a first-page render with an optional red "PDF" label band
  (`plain: true` suppresses it — used by `VariantCard`'s bare page preview). Carries a
  two-layer shadow (tight contact + wide soft) rather than a single shadow — a recorded
  divergence (§11): one shadow reads as a grey smudge at thumbnail size.

### 4.2 New (queue redesign)

All defined in `Sources/Toolbox/DesignSystem/QueueComponents.swift`.

- **`VerbChip`** — the Compress/OCR batch-wide toggle. A compound control: the label
  toggles the verb on/off, the suffix/chevron (present only once the verb is on and has
  options) opens that verb's options popover — two separate VoiceOver actions, never one
  ambiguous control.
- **`StatusIndicator`** — the queue row's one trailing status glyph. `finished` (filled
  check, pops in), `active(fraction)` (rotating accent arc), `queued` (breathing dashed
  ring), `unchanged` (outline check, `textTertiary` — a fully successful no-op row),
  `warn` (the *same* outline-check shape as `unchanged`, only re-tinted `warn` — this is
  deliberately **not** the filled warn-disc a batch-summary header draws for "this batch
  needs attention"; that is a different glyph entirely, drawn by the screen itself, not
  this component). `size` is overridable so a screen's big finished/warn header (06, 10)
  reuses the same glyph at 30pt instead of a second component.
- **`CapsuleProgressBar`** — the Working screen's batch-wide bar: gradient `accent`
  fill, a glowing leading cap, a periodic light sweep. Sweep and cap gate on Reduce
  Motion; the fill-width animation itself does not, since it communicates real progress.
- **`OptionCard`** — the Change-quality screen's equal-width card: name, predicted
  total, delta caption, selection ring. Not the quality popover's list (that is
  `RadioRow` — different screen, different shape).
- **`CapsuleBadge`** — the "N versions" pill embedded in a finished row. Two tones:
  muted/closed, accent/open. Not used for the quality popover's RECOMMENDED tag or the
  scan-choice screen's labels — those are plain coloured text with no pill background.
- **`QueueRowSizeColumn`** — the shared 70pt right-aligned current→target size column
  (Ready and Change-quality rows), so both screens compose the same column rather than
  each re-deriving the width.
- **`QueueRow`** — the one row shape spanning Ready, Working, Finished, Versions and
  Problems. Fixed mechanics: hover/keyboard focus (2px accent ring — §6), the leading
  thumbnail + name + meta, a hover- and focus-revealed gear, the versions capsule,
  problem-row tinting (`emphasis`: none / degraded / problemDanger / problemWarn), and a
  context menu mirroring every hover-only affordance for the non-hover/keyboard path.
  Trailing content is composed per screen.
- **`BatchCard`** — a recent-batch summary tile: the empty-state history strip
  (`trailingLink`, e.g. "Open folder") and the Recent-batches sheet's rows
  (`trailingValue`, a plain savings figure) — the two trailing shapes are mutually
  exclusive.
- **`VariantCard`** — the scan-choice screen's two cards. Deliberately **not** a
  button — unlike every other interactive shape in the handoff, neither card carries a
  hover state; selection happens only through the footer's two buttons. `isSelected`
  drives the ring/tint only, as a preview of the leading choice.
- **`SecondaryButton`** — a neutral filled button: "Show in Finder", "Enter
  password…", "Compare versions…", "Cancel". Dark fill is a component-local
  `#3A3A3C` (§2), not `surface`.
- **`SegmentedRow`** — a compact 2/3-way segmented control (Fast/Accurate,
  Smallest/Balanced/High). Custom-drawn to match this design system rather than
  AppKit's native `.segmented` chrome.
- **`DropdownRow`** — a labelled system dropdown (the language picker). Reuses
  `SectionLabel` for its group label — see §11 for a token gap on that shared label.
- **`ToggleRow`** — a titled system toggle with a state-line beneath it ("Rebuild the
  scan", "Read the text (OCR)").
- **`RadioRow`** — a single-select row used by two different popovers with genuinely
  different unselected chrome: the quality popover draws **no glyph at all** on an
  unselected row; the versions popover draws a **hollow ring**. `showsUnselectedIndicator`
  (default `true`, matching the more common "choosing among existing things" case) is the
  flag; the quality popover passes `false`.
- **`CheckRow`** — a plain checkbox row ("Choose which files…").
- **`PopoverChrome` / `SheetChrome` / `UpdateBannerChrome`** — shared containers.
  Popover: anchored, tail, fade + scale + rise entrance. Sheet: dim overlay, centred,
  fade + rise + scale entrance. Update banner: full-width strip under the titlebar,
  slide-down entrance. All three gate their entrance transform on Reduce Motion
  (appear instantly, no transform, when it is on).

### 4.3 Non-components

Recorded so a reader sees "no component" rather than "component missing": the `⋯` menu
and the "Saving beside the originals ⌄" control are native SwiftUI `Menu`s; the
Finished/Problems screens' large headers are composed directly from `StatusIndicator` +
`Theme` text, not a shared component; the scan-choice screen's "without asking" toggle is
a native `Toggle` + label; the About sheet's content (icon, version, links) is composed
by the app layer, not pinned here.

## 5. Layout, Spacing and Radii

**Spacing** (`Theme.Spacing`): `small` = 8, `medium` = 16, `large` = 24. Window side
padding uses `large`; row inset uses `medium`. Row padding (12) and header/footer
paddings (20 / 24 / 14–16) are screen-level constants, not named tokens.

**Radii** (`Theme.Radius`):

| Token | Value | Use |
|---|---|---|
| `pill` | 980 | Pill CTAs, compact badges (`StatPill`, `CapsuleBadge`), toggle tracks |
| `card` | 12 | Popovers (`PopoverChrome`) |
| `sheet` | 14 | Sheets (`SheetChrome`) |
| `row` | 10 | `QueueRow`, `OptionCard`, `VariantCard` |
| `control` | 8 | Buttons, verb chips |
| `input` | 11 ("Comfortable"; no handoff counterpart) | Inherited from before the redesign |

The gear button (26pt circle) and the empty-state drop icon disc are literal `Circle()`
shapes, not a named radius token.

## 6. Depth, Elevation and Focus (Accessibility)

| Level | Treatment | Use |
|---|---|---|
| Flat (Level 0) | No shadow | Most surfaces — shadow is the exception, not the default (§7) |
| Popover | `black 24%`, radius 23, y 16, + 0.5px `stroke` ring | `PopoverChrome` |
| Sheet | `black 34%`, radius 30, y 26, + 0.5px `stroke` ring | `SheetChrome` |
| Secondary button | `black 18%`, radius 1.5, y 0.5, + inset 0.5px `stroke` ring | `SecondaryButton` |
| PDFThumbnail (recorded divergence, §11) | Two stacked shadows — tight contact + wide soft | `PDFThumbnail` |
| **Focus (Accessibility)** | **2px solid `Theme.Colors.accent` outline** | Keyboard focus on every interactive element |

### Focus (Accessibility)

Every interactive element shows a **2px solid `accent`** outline when it holds keyboard
focus — `QueueRow`'s `.strokeBorder(Theme.Colors.accent, lineWidth: isFocused ? 2 : 0)` is
the pattern every focusable control follows. This is the standing invariant behind the
"stray blue focus ring" fix (`.claude/memory/20260725-stray-focus-ring-invariant.md`):

- **Keyboard-assigned focus always shows the ring.** Tab/arrow navigation assigns focus
  on a `.keyDown` event and the ring stands — this is never hidden.
- **Click-assigned focus is cleared.** A mouse click on any focusable `.buttonStyle(.plain)`
  control makes it first responder and AppKit draws a ring the user never asked for.
  Every such control carries `.clearsClickFocus()` (`DesignSystem/Components.swift`)
  unless it deliberately keeps click focus. Never re-implement this with a local
  `@FocusState` clear — that per-control approach is how the defect kept recurring.
- **Auto-assigned focus** (window re-key, a popover closing — which never takes key
  status, so a key-transition observer alone misses it — app reactivation) is swept by
  `WindowSetup.installStrayFocusClear(on:)`: a KVO watch on the main window's
  `firstResponder` that clears any assignment whose current event is not `.keyDown`.
- **`.focusEffectDisabled()` is reserved**, never reached for first: today's one carve-out
  is the About sheet, where auto-focus draws a permanent ring outside the main window's
  net. Hiding a ring anywhere else blinds keyboard users to where focus actually is.

## 7. Do's and Don'ts

### Do

- Reserve `accent` for interactive elements only — it is the entire chromatic budget;
  `link`, `success`, `warn`, `danger` are semantic state colours, not a second accent.
- Keep every button fill flat — no gradients, no glow behind a CTA.
- Use shadow only where §6 names it; most surfaces are flat, elevation comes from
  `background`/`surface` contrast, not synthetic depth.
- Reserve positive letter-spacing (+0.4) and uppercase for `sectionLabel` alone; every
  other role tracks flat or negative.
- Set every numeric value (sizes, percentages, counts, timings) with `.monospacedDigit()`.
- Give every hover-only affordance a non-hover path (keyboard focus reveal, context menu)
  — spec §9.

### Don't

- Don't introduce a second chromatic accent.
- Don't add a border to a card or container without recording why (§11 is the only
  currently-recorded exception, and it survives on one surviving component,
  `PDFThumbnail`'s shadow — not a border).
- Don't reach for `.focusEffectDisabled()` outside its one carved exception (§6).
- Don't re-implement stray-focus-ring clearing with a local `@FocusState` — use the
  shared `.clearsClickFocus()` modifier.
- Don't use `NSCursor.push()`/`.pop()` for a hover cursor — a pushed cursor is only
  balanced by a matching `onHover(false)` on the same view instance, which a removed or
  swapped-out row cannot guarantee. Use the shared `.pointingHandCursor()` modifier
  (`NSCursor.set()`-based, no stack to unbalance).

## 8. Motion

Standard curve: the handoff's `cubic-bezier(.2,.8,.25,1)`, reproduced as
`.spring(response: 0.35, dampingFraction: 0.85)` — `Theme.Motion.standard`.

| Token | Duration | Use |
|---|---|---|
| `standard` | spring(0.35, 0.85) | General transitions |
| `hover` | 0.15s | Background/opacity hover transitions |
| `press` | 0.12s | Primary-button press scale |
| `popover` | 0.3s | Popover fade + scale + rise entrance |
| `sheet` | 0.38s | Sheet fade + rise + scale entrance |
| `banner` | 0.45s (0.15s delay) | Update banner slide-down |
| `checkPop` | 0.45s | Success/warn check "pop" (scale 0.4→1.16→1); row checks delay 0.25s after the header check |

Motion not backed by a named `Theme.Motion` constant, still part of the law and driven by
local component state: the progress bar's leading-cap pulse and its 1.6s light sweep; the
Working row's shimmer (~2.4s); the active status ring's rotation (0.9s linear); the
queued dashed ring's breathing (~2s–2.2s); the drag-over fan's entrance + float loop
(70ms stagger in, 2.6–3.2s float); the empty-state icon's pointer parallax (~90ms follow,
±11°/±13° rotation, ±7px translate, 1.05 scale, glow moving in counter-phase, settling
back over 0.5s on exit).

**Reduce Motion**: every interactive `QueueComponents` view gates its transform/loop
animations on `accessibilityReduceMotion`, substituting a plain or no transition — never
skipping the underlying state change. The one exception is a progress bar's fill-width
animation, which stays under Reduce Motion because it communicates real progress, not
decoration.

## 9. Screens

Screens are cited by name, matching `Toolbox Final.dc.html`'s section labels and the
14 states enumerated in the spec. Structure and copy below are the handoff's, restated
against this document's token names.

### 01 — Empty

Centred: the real app icon at 76pt (parallax on hover — §8), "Drop PDFs to begin"
(`windowHeadline`-scale display text), "Compress them, OCR them, or both." (`textSecondary`),
a `PrimaryButton` "Choose Files…", and "Nothing leaves this Mac" beside a lock glyph
(`textTertiary`). Below a 1px `sep`: a history strip — `sectionLabel` "EARLIER TODAY" with
a right-aligned lifetime total ("1.4 GB saved since you installed Toolbox"), two
`BatchCard`s side by side with a `trailingLink` "Open folder". Hidden entirely when there
is no history.

### 02 — Drag-over

The content area tints `accent` at 5%; an inset dashed 2px `accent` ring (`row` radius)
pulses opacity 0.55→1→0.55 over 1.8s. A fan of mock PDF pages floats mid-window — count
mirrors the drag (1, 2, 3, or 3 + "+N" badge) — entering with a stagger then looping a
float. Headline: "Drop {n} PDFs" in `accent`; subtitle "Nothing runs until you press
Start." (`textSecondary`).

### 03 — Ready

Header: "{n} files" (`windowHeadline`) + total size (`body13`, `textTertiary`),
baseline-aligned; trailing `LinkButton`s "+ Add" / "⊗ Clear", a 28pt `⋯` menu (native
`Menu`). Verb-chip row: `VerbChip` Compress (active, reads "✕→ Compress · {preset} ⌄"),
`VerbChip` OCR (inactive by default). Trailing: a folder icon + "Saving beside the
originals ⌄" (native `Menu`; alternate: chosen folder name). Rows: `QueueRow` with
`QueueRowSizeColumn` trailing — name (`rowName`), one meta line (`meta`) describing
content ("48 pages, mostly photographs" / "32 pages, no text layer yet" / "12 pages, text
and vectors"). Hover reveals the gear. Below the rows: a drop hint, "Drop more PDFs
anywhere in this window" (`textTertiary`). Footer above a 1px `sep`: total → predicted
total (`bodyStrong`) over "Your originals stay exactly where they are." (`textTertiary`);
a `PrimaryButton` "Start", disabled with zero verbs on or zero healthy rows.

### 04 — Quality popover

`PopoverChrome` (330pt) anchored under the Compress chip, wrapping three `RadioRow`s
(`showsUnselectedIndicator: false` — no glyph on an unselected row), each with a
right-aligned predicted total:

- **Smallest** — "For email limits. Photographs soften." — predicted total
- **Balanced** (selected — accent-9% row, RECOMMENDED badge) — "Indistinguishable on
  screen." — predicted total
- **High quality** — "Safe to print at full size." — predicted total

Totals recompute from the estimator against the actual queue. The queue behind dims to
40% while open.

### 04b — OCR popover

Chip reads "OCR · {language} ⌄". `PopoverChrome` (350pt): `sectionLabel` "LANGUAGE ON THE
PAGE" + a `DropdownRow` (English default; curated list), `sectionLabel` "HOW CAREFULLY TO
READ" + a `SegmentedRow` (Fast/Accurate, Accurate default), a caption "Accurate takes
about three times as long and is worth it for handwriting, faint fax paper and small
print.", a hairline, and the footnote "Pages that already contain text are left alone."

### 04c — Per-file settings

`PopoverChrome` (300pt) anchored to the row's gear, right-aligned. Header: thumbnail +
filename (`bodyStrong`) + "Overrides just this file" (`textTertiary`) + close ×. A
`SegmentedRow` for quality with a context caption ("The batch is on {preset}. This one is
a signed contract, so keep it sharp."). Two `ToggleRow`s: "Rebuild the scan" (default
off — "stamps stay photographic") and "Read the text (OCR)" (state line names language +
accuracy). Footer: "Estimate **{size}**" left, a `LinkButton` "Match the batch" right
(clears overrides). An overridden row's meta line turns accent "Its own settings"; the
batch footer notes "One file has its own settings, so its estimate differs from the
batch."

### 05 — Working

Header: "Working on {n} files" (`windowHeadline`) beside "{pct}% · about {n} seconds
left" (`body13`, `textTertiary`); trailing a `LinkButton` "Cancel". Below: a full-width
`CapsuleProgressBar`. Each `QueueRow`'s trailing carries a `StatusIndicator` in its single
16–18pt status slot: **finished** — green check, meta "{pct}% smaller · finished in {n}
seconds", sizes filled; **active** — accent-tinted row with a slow shimmer, meta accent
"Reading page {n} of {m}", trailing "{n}s left"; **queued** — 50% opacity, meta "Next".
Footer: "{total} saved so far" (`bodyStrong`) / "Toolbox works several files at once on
your Mac's fastest cores." (`textTertiary` — see §11, D2 divergence); a `SecondaryButton`
"Cancel". Finished files are banked immediately, not held to batch end.

### 06 — Finished

Header: a 30pt green check (via `StatusIndicator(.finished, size: 30)`) + "{total} lighter"
(`windowHeadline`) + "{before} → {after} across {n} files. One is now searchable."
(`textSecondary`). Rows: outcome meta lines — "Rebuilt and searchable · 78% smaller",
"75% smaller · saved as {name}-compressed.pdf", "Already optimised". Trailing: a versions
`CapsuleBadge` where a second variant exists, old size → new size (`rowName`) + a
`StatusIndicator(.finished)`; a no-op row shows grey sizes + `StatusIndicator(.unchanged)`.
Row click opens the file. Footer: "Saved in {folder}" / "Click any file to open it.
Changed your mind? Pick a different quality." — `SecondaryButton` "Show in Finder",
`SecondaryButton` "Change quality" (→ 08), `PrimaryButton` "Add More". Header numbers are
always computed from the actual rows, never hard-coded.

### 07 — Versions popover

Opened from a row's versions `CapsuleBadge` (turns accent while open; row meta reads
"Choosing a version"). `PopoverChrome` (312pt) anchored **below** the row, tail centred on
the capsule. Header: thumbnail + filename + "Switch any time before you quit" + ×. Three
`RadioRow`s (`showsUnselectedIndicator: true` — the one place a hollow ring shows on
unselected rows): **Rebuilt · {size}** (selected, accent subtitle "In use. Text sharp,
paper texture smoothed."), **Photographs · {size}** ("Pages untouched, only lighter."),
**Original · {size}** ("Never modified, still in its folder."). Selecting swaps the file
on disk instantly. Footer: full-width `SecondaryButton` "Compare versions…" (opens both in
Preview). Searchability suffixes on each subtitle are a recorded divergence — see §11.

### 08 — Change quality

Title "Different quality for these {n} files"; trailing "Applies to all {n} files ·
Choose which files…" (`LinkButton`). Three `OptionCard`s (equal flex): name
(`bodyStrong`), predicted total + delta caption — "Smallest — {size} / {delta} less"
(success tone), "Balanced — {size} / what you have" (muted tone), "High quality —
{size} / for printing" (selected — accent ring + tint). Rows state the mechanism per
file: "Redone from the original at {n} DPI · about {n}s" or "Already on disk — swapped in
immediately" (when the variant already exists), "Already optimised — nothing to change"
(unchanged sizes). Footer: total → predicted total; `SecondaryButton` "Cancel" +
`PrimaryButton` "Switch to {preset}". Works in both directions (smaller and sharper).

### 09 — Scan choice (consent)

Title "{filename} came out two ways"; trailing caption "Both are on disk. Nothing is
decided yet." Two `VariantCard`s: **Rebuilt in layers** (badge "BEST FOR SCANS", accent —
"{size} · {pct}% smaller"; explanation "Letters are traced and stay crisp at any zoom. The
paper behind them is flattened, so grain, shadows and coffee rings disappear.") vs. **Left
as photographs** (badge "NOTHING REDRAWN" — "{size} · {pct}% smaller"; explanation "Each
page stays a picture of the paper, just lighter. Choose this when the sheet itself is
evidence — signatures, stamps, handwriting."). Below: a native `Toggle` "Rebuild scans
from now on without asking" + a `LinkButton` "Open both in Preview". Footer: "The one you
don't keep is deleted when you quit." + equal-weight `SecondaryButton` "Keep photographs"
/ `PrimaryButton` "Keep rebuilt". If a card's honest numbers undercut this copy (e.g. the
rebuilt file is larger), the card states the truth — percentages never lie; only the copy
above is fixed (§11).

### 10 — Problems

Header: a 30pt warn glyph (`StatusIndicator(.warn, size: 30)`) + "{n} of {m} files done" +
"{total} saved. Two files need something from you." Problem rows: `QueueRow` with
`.emphasis(.problemDanger)` (danger tint 7%) or `.problemWarn` (warn tint 10%) — meta
states the condition ("Needs a password to open" / "Moved or renamed since you added it")
with the fix beside it: a `SecondaryButton` ("Find it…" — password entry does not ship,
see the spec's non-goals) + a `LinkButton` ("Skip" / "Remove"). A degraded outcome shows
`.emphasis(.degraded)` (no tint) + `StatusIndicator(.warn)`: "Too faint to read —
compressed, but not searchable". Footer: "Files that failed were not touched at all." +
`PrimaryButton` "Add More".

### 11 — Recent batches / Update banner / About

**Recent batches** (`⋯` menu): `SheetChrome` (520pt, 52px below the titlebar, over a
`black 22%` dim). Title + "{total} saved in total". Grouped by `sectionLabel`
TODAY/YESTERDAY; rows: a status square, "{n} files in {folder}" (`bodyStrong`), "{time} ·
{preset} · one made searchable" (`caption`), a right-aligned savings figure
(`bodyStrong`, success — "no change" in grey for an OCR-only batch) via `BatchCard`'s
`trailingValue`. Row click opens the folder. Footer: "Kept on this Mac. Clearing it
doesn't delete any files." + a "Clear list" link + a `PrimaryButton` "Done".
**Update banner** (`UpdateBannerChrome`, under the titlebar): a download-circle icon, "A
newer version {version} is available", trailing a `LinkButton` "See what changed" (→ the
release's tag page) + `PrimaryButton` "Update" + a × dismiss (persists per-version).
**About** (`⋯` menu and app menu): `SheetChrome` (330pt) — the app icon at 84pt (same
parallax), "Toolbox" (19/semibold), "Version {version} · macOS 14 or later" (12.5,
`textTertiary`), "Free PDF tools that never phone home. / No account, no subscription, no
watermark." (`body13`, `textSecondary`, centred), links "Source Code" · "Licence" ·
"Contact me", "© 2026 Vilmar Rosset · AGPL-3.0" (11, `textTertiary`), × close.

### 12 — Dark

Structurally identical to every screen above; every token in §2 resolves to its dark
value. Row hover uses `background`'s dark value; check glyphs stroke against `surface`'s
dark value for contrast; `SecondaryButton`'s dark fill is the component-local `#3A3A3C`
(§2), not `surface`.

## 10. Copy Register

Fixed strings, verbatim. `{}` marks a computed value — never hard-code the number it
stands for.

| Context | Copy |
|---|---|
| Empty-state headline | "Drop PDFs to begin" |
| Empty-state subtitle | "Compress them, OCR them, or both." |
| Empty-state privacy note | "Nothing leaves this Mac" |
| Empty-state history label | "EARLIER TODAY" (and other date groups) |
| Empty-state lifetime total | "{total} saved since you installed Toolbox" |
| Drag-over headline | "Drop {n} PDFs" |
| Drag-over subtitle | "Nothing runs until you press Start." |
| Ready — clear all | "⊗ Clear" |
| Ready — add more | "+ Add" |
| Ready — save destination | "Saving beside the originals ⌄" |
| Ready — drop hint | "Drop more PDFs anywhere in this window" |
| Ready — footer note | "Your originals stay exactly where they are." |
| Quality popover — Smallest | "For email limits. Photographs soften." |
| Quality popover — Balanced | "Indistinguishable on screen." |
| Quality popover — High quality | "Safe to print at full size." |
| Quality popover — badge | "RECOMMENDED" |
| OCR popover — labels | "LANGUAGE ON THE PAGE", "HOW CAREFULLY TO READ" |
| OCR popover — accuracy caption | "Accurate takes about three times as long and is worth it for handwriting, faint fax paper and small print." |
| OCR popover — footnote | "Pages that already contain text are left alone." |
| Per-file settings — subtitle | "Overrides just this file" |
| Per-file settings — rebuild toggle off-state | "stamps stay photographic" |
| Per-file settings — match batch | "Match the batch" |
| Per-file settings — override note | "Its own settings" / "One file has its own settings, so its estimate differs from the batch." |
| Working — footer | "Toolbox works several files at once on your Mac's fastest cores." (§11 divergence) |
| Working — active row meta | "Reading page {n} of {m}" |
| Working — queued row meta | "Next" |
| Finished — subtitle | "{before} → {after} across {n} files. One is now searchable." |
| Finished — footer | "Saved in {folder}" / "Click any file to open it. Changed your mind? Pick a different quality." |
| Versions popover — header | "Switch any time before you quit" |
| Versions popover — rebuilt subtitle | "In use. Text sharp, paper texture smoothed." |
| Versions popover — photographs subtitle | "Pages untouched, only lighter." |
| Versions popover — original subtitle | "Never modified, still in its folder." |
| Versions popover — compare | "Compare versions…" |
| Change quality — title | "Different quality for these {n} files" |
| Change quality — scope link | "Applies to all {n} files · Choose which files…" |
| Change quality — mechanism (already on disk) | "Already on disk — swapped in immediately" |
| Change quality — mechanism (re-run) | "Redone from the original at {n} DPI · about {n} seconds" |
| Change quality — no change | "Already optimised — nothing to change" |
| Scan choice — title | "{filename} came out two ways" |
| Scan choice — subtitle | "Both are on disk. Nothing is decided yet." |
| Scan choice — rebuilt badge / explanation | "BEST FOR SCANS" / "Letters are traced and stay crisp at any zoom. The paper behind them is flattened, so grain, shadows and coffee rings disappear." |
| Scan choice — photographs badge / explanation | "NOTHING REDRAWN" / "Each page stays a picture of the paper, just lighter. Choose this when the sheet itself is evidence — signatures, stamps, handwriting." |
| Scan choice — preference toggle | "Rebuild scans from now on without asking" |
| Scan choice — compare | "Open both in Preview" |
| Scan choice — footer note | "The one you don't keep is deleted when you quit." |
| Scan choice — buttons | "Keep photographs" / "Keep rebuilt" |
| Problems — header | "{n} of {m} files done" / "{total} saved. Two files need something from you." |
| Problems — locked | "Needs a password to open" |
| Problems — moved/renamed | "Moved or renamed since you added it" |
| Problems — degraded | "Too faint to read — compressed, but not searchable" |
| Problems — fix affordances | "Find it…" / "Skip" / "Remove" |
| Problems — footer | "Files that failed were not touched at all." |
| Recent batches — title/footer | "{total} saved in total" / "Kept on this Mac. Clearing it doesn't delete any files." |
| Recent batches — controls | "Clear list" / "Done" |
| Update banner | "A newer version {version} is available" / "See what changed" / "Update" |
| About — identity | "Toolbox" / "Version {version} · macOS 14 or later" |
| About — tagline | "Free PDF tools that never phone home. / No account, no subscription, no watermark." |
| About — links | "Source Code" · "Licence" · "Contact me" |
| About — copyright | "© 2026 Vilmar Rosset · AGPL-3.0" |

## 11. Divergences from the Handoff

Every deliberate departure from the handoff's visual/copy law, each with its authority.
A divergence is recorded here or it does not exist (`CODE_GUIDELINES.md` §8.4).

- **`LinkButton` renders at 14pt; the handoff specifies 13pt** ("+ Add"/"⊗ Clear" links,
  README: "13/link"). App-wide, not one screen — every `LinkButton` call site (Ready's
  "+ Add"/"⊗ Clear", "Match the batch", "See what changed", the Problems screen's
  Skip/Remove, `BatchCard`'s "Open folder"). Only the **size** diverges — tracking stays
  the incumbent −0.224 (§3). Plan-pinned (Task F7); not a defect to silently correct.
- **`PDFThumbnail`'s two-layer shadow** (tight contact + wide soft) rather than a single
  treatment (DECISIONS 2026-07-25) — a single mid-radius shadow reads as a grey smudge at
  thumbnail size.
- **Combined-pass "grew" state** (spec §6.3): when a compress+OCR pass nets a larger file
  (small compression gain, larger text layer), the row shows honest sizes ("12.4 MB →
  13.1 MB") with meta "Searchable now · grew slightly". The handoff has no "grew" state —
  honesty over fidelity.
- **Working-screen footer copy** (spec §6.8): "Toolbox works several files at once on
  your Mac's fastest cores." replaces the handoff's "Toolbox uses one core at a time, so
  your Mac stays responsive." — the app runs P-core-parallel by design (human decision
  D2), so the handoff's line would be false.
- **Versions-popover searchability suffixes** (spec §6.4): a version's subtitle gains
  " · Not searchable" or " · Searchable" when the row's effective verb set includes OCR —
  no handoff string exists for this state.
- **Scan-choice card honesty** (spec §7): if a card's honest numbers undercut its fixed
  copy (e.g. the rebuilt file is larger than the alternative), the card states the truth;
  percentages and sizes never lie even when the fixed strings in §10 imply a direction.
- **Compress-failure rescue copy** (spec §6.5) — none of the following four strings
  exist in the handoff, which has no state for a compress-specific engine failure:
  - the successful OCR-only rescue's row meta names the compress failure, e.g.
    "Couldn't be compressed — made searchable instead";
  - the no-gain+OCR composite rows: "Already optimised · made searchable" and "Already
    optimised · too faint to read";
  - the compress-failure-with-OCR-off problem row: "Couldn't be compressed" (with the
    same Skip/Remove affordances as any other problem row);
  - the switch re-run's no-such-version line: "That version is no longer available —
    kept your {preset} version." (composed from strings already in this register).
- **Problems footer (§9 screen 10) gains a secondary Start** when `canStart` is true —
  the handoff depicts only "Files that failed were not touched at all." + `PrimaryButton`
  "Add More". Authority: review-team r4 adjudication, ladder key
  `QueueView.screenState` tier-3, commit 5cfb1f4. Rationale: spec §7's "the batch keeps
  going" — a clean pending row added from the Problems screen (via Add More) must stay
  startable without first resolving the unrelated failure; Add More stays the one filled
  `PrimaryButton`, Start joins as a `SecondaryButton` so screen 10 keeps its single accent
  CTA. With nothing runnable the footer renders exactly as the handoff depicts.

**Reported, not resolved** (found while writing this document; for whoever owns the
named surface next):

- `Theme.Typography.sectionLabel` (11/semibold/+0.4, §3) is correctly specified and
  matches the handoff, but nothing renders through it yet: the `SectionLabel` view
  (`Components.swift`) still hard-codes `.microBold` (12pt) with a manual `.tracking(0.4)`
  override. Every current call site but one dies with its file in Task I1b
  (`CompressView`, `OCRView`, `SidebarView`); the sole survivor is `QueueComponents.swift`'s
  `DropdownRow` label (screen 04b). Whoever finishes that screen should retone
  `SectionLabel` onto the `sectionLabel` case.
- `Theme.Radius.input` (11, "Comfortable") has no handoff counterpart and, per its own
  doc comment, exists only for `SegmentedPreset` and `Card` — both slated for deletion in
  Task I1b. It may become an orphaned token once that task lands.
- `Theme.Shadow` (the pre-redesign generic card shadow) has no per-context counterpart in
  the handoff and its sole consumer, `Card`, is deleted in Task I1b — it is not carried
  into §6 above and is likely orphaned once I1b lands.
- Two prior recorded divergences no longer apply and should not be re-added: per-tool
  sidebar tints (DECISIONS 2026-07-23) and the non-interactive `accent` uses on
  `SuccessBanner`/`FileRow` (DECISIONS 2026-07-26) — their subjects (`SidebarView`,
  `Tool.tint`, `SuccessBanner`, `FileRow`) are all deleted by this redesign.
