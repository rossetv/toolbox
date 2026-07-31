<!-- Claude-maintained; humans never edit. THE registry: every file under
.claude/ has a row in "KB docs" unless exempt — an unregistered non-exempt file is a defect (registry rules
and the exemption list are the single source in CLAUDE.md § Project Knowledge
Base). kb-updater
reconciles this table against disk and code every run. Verified stamps live
ONLY here (date @ short sha of the commit verified against). Injected verbatim
every session, never truncated; registry and module rows are never dropped for
size — compress elsewhere first. Repos outgrowing a single-level index
(roughly >40 modules) split into area sub-indexes, only when actually needed:
past 40 modules the module table groups rows under area headings (grouping
only, still one table); area sub-index files stay unbuilt until a real repo
actually needs them.
Hard byte ceiling: ≤8,000 B — its SessionStart block is the file alone (10,000-char hook cap, 8,000 B per-block budget). -->

# Toolbox — KB Index

## KB docs

| Doc | Purpose | Verified |
|-----|---------|----------|
| [OVERVIEW](OVERVIEW.md) | system summary — always injected | 2026-07-31 @ 79a54a0 |
| [DECISIONS](DECISIONS.md) | append-only decision log | 2026-07-27 @ 9a14a90 |
| [MEMORY](MEMORY.md) | project memory index — always injected | 2026-07-25 @ b2d0a6f |
| [GATES](GATES.md) | the gates that define "done" — Claude's runbook | 2026-07-26 @ 9f89b0e |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | module map, flows, invariants | 2026-07-31 @ 79a54a0 |

## Modules

| Module | Purpose | Entrypoint | Doc |
|--------|---------|-----------|-----|
| App | Shell: entry point, single-pane window + window setup, self-update, smoke tests | `Sources/Toolbox/App/ToolboxApp.swift` | [→](docs/modules/app.md) |
| Queue | The unified queue: one view model, every screen, progress/ETA, consent + version switch, history | `Sources/Toolbox/Queue/QueueViewModel.swift` | [→](docs/modules/queue.md) |
| Compress | Rung-1 (Ghostscript) + Rung-2 (bilevel/CCITT) + Rung-3 (MRC) compression, estimate | `Sources/Toolbox/Compress/CompressEngine.swift` | [→](docs/modules/compress.md) |
| OCR | Vision-based invisible text layer | `Sources/Toolbox/OCR/OCREngine.swift` | [→](docs/modules/ocr.md) |
| Services | gs runner + sandbox, PDF inspection, output validation, PDF writer | `Sources/Toolbox/Services/GhostscriptRunner.swift` | [→](docs/modules/services.md) |
| Shared | Batch runner, file naming, path canonicalisation, file picker, system info | `Sources/Toolbox/Shared/ToolQueue.swift` | [→](docs/modules/shared.md) |
| Models | Tool-agnostic value types (job/preset/content-type/estimate) | `Sources/Toolbox/Models/ToolJob.swift` | [→](docs/modules/models.md) |
| DesignSystem | Theme tokens + reusable SwiftUI components | `Sources/Toolbox/DesignSystem/Theme.swift` | [→](docs/modules/design-system.md) |

## Goal → start here

| Goal | Start at |
|------|----------|
| Understand the system | [OVERVIEW](OVERVIEW.md) → [ARCHITECTURE](docs/ARCHITECTURE.md) |
| Change how gs is sandboxed/invoked | [modules/services](docs/modules/services.md) |
| Change the compression pipeline/presets | [modules/compress](docs/modules/compress.md), [modules/models](docs/modules/models.md) |
| Change OCR recognition/embedding | [modules/ocr](docs/modules/ocr.md) |
| Change the window's screens, rows or run flow | [modules/queue](docs/modules/queue.md) |
| Change the window setup, self-update or smoke tests | [modules/app](docs/modules/app.md) |
| Change batch/queue/naming behaviour | [modules/queue](docs/modules/queue.md), [modules/shared](docs/modules/shared.md) |
| Change visual styling | [modules/design-system](docs/modules/design-system.md), root `DESIGN.md` |
| Check what "done" means / run the gates | [GATES](GATES.md) |

## Human docs (read-only for Claude)

| Doc | Covers |
|-----|--------|
| `DESIGN.md` | visual language — reviewer enforces on UI diffs |
| `LICENSE` | AGPL-3.0-or-later, full text |

## Central vs peripheral

- **Central** (changes fan out to both legs of the pass): `Sources/Toolbox/Services/`
  (gs runner, sandbox profile, PDF inspection/validation/writer), `Sources/Toolbox/Shared/`
  (batch runner, naming, path canonicalisation).
- **Peripheral** (isolated): `Sources/Toolbox/DesignSystem/` (presentation only, no
  logic dependents), `Sources/Toolbox/Models/` (leaf value types, no outward
  dependencies).
