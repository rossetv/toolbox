<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every command below must be verified to RUN
before it is written here; a gate that has never been run is not a gate.
NEVER cite a line number. Cite a file plus a stable, greppable anchor. -->
↑ [INDEX](INDEX.md)

# Gates — Toolbox

<!-- An operator's RUNBOOK: how to CHECK the work and confirm it passes. -->

## DO NOT CHEAT. NEVER BYPASS A GATE.

**A red gate means the work is not done. It does not mean the gate is wrong.**

The cheapest way to turn a red gate green is to edit this file and delete the gate.
That is cheating, and it will not feel like cheating at the time — it will feel like
*"this gate was stale anyway."* That feeling is the failure mode, not a finding.

Adding a gate is cheap. **Removing or editing a gate requires a `/panel`** — never a
single Claude's decision. Log the outcome to `DECISIONS.md`.

**Never edit the thing a gate points at in order to make the gate pass.** Do not
delete or `.skip` a failing test. Do not gut a script a gate invokes.

Never `--no-verify`. If you cannot make a gate pass, **stop and say so** — that is a
legitimate, respectable outcome. Silently weakening the standard is not.

All commands run from the repo root, on macOS 14+, Apple Silicon.

## Mechanical gates

### gate: ghostscript-builds
kind: mechanical
why: The app shells out to a bundled `gs`; if it does not build, verify its pinned source digest, and run self-contained, Compress cannot work at all on a user machine.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
scripts/build-ghostscript.sh && env -i Resources/ghostscript/bin/gs --version
```

### gate: ghostscript-self-contained
kind: mechanical
why: The bundled `gs` ships inside the .app. If it links a Homebrew dylib it works here and breaks on every user machine — a class of defect no test would catch locally.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
test -x Resources/ghostscript/bin/gs && { otool -L Resources/ghostscript/bin/gs | tail -n +2 | grep -qv -e '/usr/lib/' -e '/System/' && exit 1 || exit 0; }
```

### gate: project-generates
kind: mechanical
why: The `.xcodeproj` is generated from `project.yml` and git-ignored; a `project.yml` that does not generate leaves the repo unbuildable from a fresh clone.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
xcodegen generate
```

### gate: builds
kind: mechanical
why: Catches compile breakage before it reaches a packaged artefact.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug build
```

### gate: tests
kind: mechanical
why: The suite covers the engine safety rules that protect user files — never overwrite the input, never emit a larger file, reject corrupt or content-losing output, cancel leaves nothing behind, and the OCR verbatim-prefix invariant.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test
```

### gate: packaged-app-compresses
kind: mechanical
why: A green unit suite does not prove the SHIPPED bundle works: the app must find its bundled `gs`, launch it under the seatbelt sandbox, and actually compress. This is the end-to-end check that the artefact users receive is functional.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

```sh
D="$(mktemp -d)"; trap 'hdiutil detach "/Volumes/Toolbox" -quiet 2>/dev/null; rm -rf "$D"' EXIT; hdiutil detach "/Volumes/Toolbox" -quiet 2>/dev/null; set -e; scripts/package-dmg.sh; hdiutil attach dist/Toolbox.dmg -nobrowse -quiet; cp -R "/Volumes/Toolbox/Toolbox.app" "$D/"; TOOLBOX_SMOKE=compress "$D/Toolbox.app/Contents/MacOS/Toolbox" | grep -q "SMOKE PASS"
```

## Semantic gates

<!-- Verified by the adversarial-reviewer agent — on OPUS, never a lesser model. -->

### gate: no-personal-corpus-references
kind: semantic
why: This repository becomes public. The maintainer's private local PDF corpus must never be identifiable from it, and a regex alone cannot judge whether a description is genuinely anonymised. An earlier round leaked a literal path into a committed document and every commit after it.
assertion: No file in the diff identifies the maintainer's machine or private material in ANY form — apply this by its intent above, never by the literal nouns it happens to name. That includes absolute home paths, the macOS account name, private directory names (the PDF corpus, design mockups, or anything else outside this repository), and any description of the corpus's contents or subject matter. Test fixtures must be synthetic and generated in-process. Measurements are acceptable only as fully anonymised aggregates. A first scrub missed a second leak precisely by reading an earlier, narrower wording literally.
added: 2026-07-23 — monocratic (opus)
mandated-by-human: no

## Gates deliberately absent

<!-- Lint/format gates are absent: the project has no linter configured, and a gate
whose command has never been run is not a gate. Add one with the linter, not before. -->

## Retired
