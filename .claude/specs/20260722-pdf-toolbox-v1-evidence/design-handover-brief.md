# Toolbox — Design Handover Brief

**For: Claude Design.** **From: the engineer who'll implement your output in SwiftUI.**
**Companion file:** `mockup.html` (my rough layout/state draft — translate it to macOS-native, don't copy it literally).

---

## 1. What you're designing

A **native macOS desktop app** (SwiftUI, macOS 14+, Apple Silicon). Named **Toolbox** — an extensible toolbox of PDF utilities. **v1 ships one tool: Compress** (shrink large PDFs a lot while preserving quality). The sidebar must read as "room for more tools", but you only design **Compress** now (Merge/Split appear as dimmed "Soon" placeholders only).

**Critical framing:** this is a **Mac app, not a web page**. Design in macOS idioms — a real resizable window, a source-list sidebar (`NavigationSplitView`), native controls, **SF Symbols**, system **materials/vibrancy**, standard macOS toolbar and spacing. `mockup.html` is HTML only because that's my drafting medium; give me the **macOS-native** version.

## 2. Design system — MANDATORY

Follow `DESIGN.md` (Apple design language) in the repo **exactly**. Non-negotiables:
- **Colour:** light bg `#f5f5f7`, dark bg `#000000`, primary text `#1d1d1f` (light) / `#ffffff` (dark), secondary `rgba(0,0,0,0.8)`, tertiary `rgba(0,0,0,0.48)`. **Single accent: Apple Blue `#0071e3`** for interactive elements ONLY. Links `#0066cc` (light) / `#2997ff` (dark). **No other accent colours.**
- **Type:** SF Pro Display ≥20px, SF Pro Text <20px. Negative tracking at all sizes. Follow the DESIGN.md type scale.
- **Shape:** buttons/cards 8px, search/filter 11px, panels 12px, **pill 980px for link-style CTAs**, circle for media controls.
- **Depth:** one soft shadow (`rgba(0,0,0,0.22) 3px 5px 30px`) or none; **no borders on cards**, no gradients, no heavy/multi shadows.
- **Both light AND dark mode.** macOS users switch; deliver both. Dark uses `#000` + the DESIGN.md dark surface tones (`#272729`–`#2a2a2d`).

## 3. Structure & navigation

- **Sidebar** (translucent/vibrant source list): app title "Toolbox", a "Tools" section, **Compress** (selected/active in Apple Blue), then **Merge** and **Split** dimmed with a "Soon" pill. Sidebar collapsible per macOS norms.
- **Detail pane:** the Compress tool (header + working area).

## 4. Screens & states to design (Compress) — the core deliverable

Design each at high fidelity, light + dark:

1. **Empty** — inviting drag-and-drop zone ("Drop PDFs here"), a "Choose Files…" affordance, note that batch is supported. Include the **drag-hover** variant (something dragged over the window).
2. **Ready / queued** — file list; the 3-preset selector; the output-location control; the primary **Compress** CTA. Header line summarising count + total size.
3. **Compressing** — per-file progress + one overall progress; a **Cancel**.
4. **Done** — per file: original → new size + "% saved"; a **summary banner** ("Saved 35.8 MB · 74% smaller"); **Reveal in Finder** + **Compress More**.
5. **Error / partial** — how a file that can't be processed (encrypted / corrupt) appears **inline in the list** (per-row error state) while the rest of the batch continues; and the "already optimised — kept original" state for a file GS couldn't shrink.

## 5. Components to spec (with all their states)

- **Drop zone** — idle + drag-hover.
- **File-queue row** — icon, filename, size + page count, remove control. Variants: *queued* / *in-progress* (determinate bar) / *done* (original→new + saved badge) / *error* / *already-optimised*.
- **Preset selector** — 3 options: **Smallest**, **Balanced** (default), **High quality**; each = title + one-line descriptor + a DPI hint. Selected state in Apple Blue. (Cards vs segmented — your call; cards shown in mockup.)
- **Output control** — "Save to: Alongside originals · `<name>-compressed.pdf`" + a "Change…" folder picker.
- **Buttons** — primary (blue, e.g. "Compress 3 PDFs"), plain/secondary, pill link ("Reveal in Finder ›").
- **Progress** — determinate per-file bar + overall bar. (Note: real output size is only known *after* processing — no pre-estimate; an indeterminate treatment may be needed briefly.)
- **Summary banner** (done state).
- **Toolbar affordances** — Add (＋), Clear.

## 6. Behaviour the visuals must support (so states are complete)

- Drag-and-drop multiple PDFs onto the window; also "Choose Files".
- **Batch** processing; UI shows per-file + overall progress; **cancellable** mid-run.
- **Originals never modified.** Output is `<name>-compressed.pdf` **next to the original** by default; optional **batch output folder** override.
- **Never produce a larger file** — if the engine can't shrink it below the original, show "already optimised", keep the original.
- Text/vectors are always preserved (engine keeps them) — nothing is flattened; no "quality warning" needed on that front.
- macOS keyboard/menu conventions (⌘O to add, ⌫ to remove selected, standard window menus).

## 7. Assets & SF Symbols

Suggest SF Symbol names per element (I'll wire them). Starting ideas: Compress `arrow.down.circle` / `rectangle.compress.vertical`; Merge `arrow.triangle.merge`; Split `arrow.triangle.branch`; Add `plus`; Remove `xmark`; Reveal `folder`; Done `checkmark.circle.fill`; Drop `arrow.down.doc`. If you want a custom **app icon**, propose one in Apple's rounded-rectangle style (a document + downward compress motif) — otherwise I'll stub it.

## 8. What I need back (handover format)

- **High-fidelity mockups** of every state above, **light + dark**.
- A **SwiftUI-implementable style spec**: exact colours, type styles (SF face/size/weight/tracking/line-height per role), spacing, corner radii, materials/vibrancy, every component's per-state appearance, SF Symbol names, and any motion/transitions.
- **Layout metrics**: sidebar width, paddings, min window size, content max-width, grid.
- Any **custom assets** as SVG (or PNG @1x/@2x).
- **macOS-native mapping notes** where helpful (which SwiftUI control / material realises each element) so it's buildable, not just pretty.

## 9. Don'ts

- No accent colour other than Apple Blue; no gradients, textures, heavy or layered shadows, or card borders.
- Don't design the Merge/Split tools — placeholders only.
- Don't make it feel like a web app — macOS-native, reductive, effortless. The tool should feel like it belongs in Apple's own suite.
