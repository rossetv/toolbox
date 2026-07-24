# Review lessons — Toolbox

Standing checks distilled from this repo's review rounds. Read before writing a spec or plan, and
apply as a checklist during review.

## Documents (spec/plan gates)

- **Never quote a sensitive value in the document that forbids it.** A privacy rule written as
  "never commit anything about the corpus at `<literal path>`" leaks the very path it protects —
  and once committed it is in every later commit. State the constraint abstractly; keep the value
  out of the repo entirely.
- **Build the whole shared layer in the serial foundation phase, before the parallel fork.** A
  spec-designated shared module placed inside one feature track leaves a sibling track needing it —
  which is a track-independence violation, not a scheduling detail.
- **Check the topological order of type definitions against phase order.** A foundation-phase type
  referencing a later-phase type does not compile, and the failure lands at the worst moment.
- **Worktree-isolated parallel tracks cannot compile against symbols that exist only in a sibling's
  worktree.** "Derives from" across concurrent tracks is a *compile* dependency, not a design one.
- **A per-job queue closure needs a progress channel and an error channel**, not just a success
  return — otherwise live progress and per-item failure are unrepresentable and the states are dead.
- **"Append-only / original untouched" claims for container formats over-state byte identity.**
  Attaching content supersedes container objects; audit the invariant against format mechanics.

## Sandboxes and subprocesses

- **Validate a sandbox profile by running the target binary under it, never by reading the profile.**
  A plausible profile (right imports, right denies) still failed to `exec` the child for want of
  `(allow process-exec*)`. Only an empirical launch proves confinement *and* function.
- **A `process-exec` allow scoped by `(literal <path>)` fails when the runtime exec path differs by
  symlink resolution.** Canonicalise both sides with C `realpath` — Swift's `resolvingSymlinksInPath`
  does NOT resolve `/var` → `/private/var`.
- **A sandboxed child cannot inherit the parent app's TCC grant.** Stage I/O through a non-protected
  temp directory so the child never touches a user-protected path.
- **A watchdog that only sends SIGTERM is not a watchdog.** Escalate to SIGKILL.

## Image and file handling

- **Never walk a CGImage buffer flat.** Rows are padded to an alignment boundary and the padding
  bytes are zero — they read as black and inflate any ink/coverage measurement by roughly the
  padding fraction, which is the same order as a blank page's true content. Address rows via
  `bytesPerRow` and sample only across the real `width`.
- **Calibrate a threshold only after the measurement is known-correct.** Thresholds tuned on a
  polluted metric encode the pollution.
- **Detect content loss relative to the input, not against an absolute floor.** A legitimately
  sparse page sits below any fixed "blank" threshold; comparing against the same input page is
  self-calibrating and does not false-fail real content.
- **Allocate batch output names up front, serially, before concurrent work starts.** A check-then-use
  against the filesystem races: two inputs sharing a basename both claim the same target.

## Test doubles and displays

- **A stub whose write semantics differ from production greens a dead feature.** A stub that
  overwrites where the real code refuses to overwrite (atomic move onto an existing path) let a
  broken re-run path pass its test; make doubles reproduce the production contract that matters
  (here: never-overwrite delivery), not just the output bytes.
- **A verifier whose reference renders through the same degraded path cannot see the
  degradation.** When candidate and reference are both produced at the same clamped resolution,
  equal-degradation scores as perfect; guard the input (a floor that declines) rather than
  trusting the comparison.
- **After fixing a state-display bug, grep every sibling aggregator over the same enum.** The
  per-row badge fix left the batch banner summing the same outcome as zero; the sibling was one
  function away and a one-line grep would have caught it in the same commit.

## Field-defect fix rounds

- **A guard that protects one spec rule by silently violating another is a finding, not a fix.**
  Resolve the conflict explicitly (here R6 vs R7: park the *original* as the runner-up) and record
  the interpretation in DECISIONS — never let a review-round patch quietly narrow the spec.
- **Measure a proposed signal before building it, in its final definition.** Two of three
  audit-proposed fixes here were reversed by measurement: an off-ink luminance signal separated in
  the wrong direction, and a "background-only" refinement *worsened* the separation it was meant to
  improve. Pin thresholds only from numbers produced under the exact definition that ships.
- **A SwiftUI collection feeding `.quickLookPreview` must never shrink while the panel is alive**
  (KVO trap in `QLPreviewPanelController`). Freeze the items into `@State` at preview-open,
  overwrite-only — clearing on dismiss re-enters the same trap inside the teardown window.

## Shipping under time pressure

- **When a hand-rolled parser has several corruption paths and time is short, prefer an
  invariant-based fail-loud net over patching the parser.** Validating a strong invariant (here: the
  original file must be the output's verbatim prefix) neutralises the known bugs *and the unknown
  ones*, converting silent corruption into a visible per-file skip. Fix the parser later.
- **The ship gate is "no silent corruption", not "every finding fixed".** Rank findings by whether
  they can damage or misrepresent user data, not by count.
- **Re-build and re-test the shipped artefact from the final tree.** An artefact built before the
  last round of fixes is a stale binary, however green the tree is.
- **One fix per commit, full suite after each, revert anything that cascades.** A green tree with
  fewer fixes beats a half-refactored broken one — especially with nobody awake to unblock it.
