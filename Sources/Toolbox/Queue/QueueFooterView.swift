// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The window's bottom bar across every non-empty screen state: screen 03's estimate + Start,
/// screen 05's saved-so-far + Cancel, screen 06's save location + Show in Finder/Change
/// quality/Add More, screen 10's "files that failed…" + Add More (plus Start while the batch still
/// has runnable work — `showsStart`).
struct QueueFooterView: View {
    @ObservedObject var model: QueueViewModel
    let state: QueueScreenState
    let onStart: () -> Void
    let onCancel: () -> Void
    let onShowInFinder: () -> Void
    let onChangeQuality: () -> Void
    let onAddMore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            // Both halves swap wholesale between states (estimate → saved-so-far → save
            // location; Start → Cancel → the finished trio), so each crosses over rather than
            // cutting. The animation itself is `QueueView`'s, scoped to `screenState`.
            leading.transition(.opacity)
            Spacer(minLength: Theme.Spacing.small)
            trailing.transition(.opacity)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.surface)
    }

    @ViewBuilder
    private var leading: some View {
        switch state {
        case .empty:
            EmptyView()
        case .ready:
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.readyHeadline(model: model)).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text(Self.readySubline(model: model)).themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .working:
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.workingHeadline(model: model)).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                // D2's recorded copy divergence (spec §6.8): concurrency stayed P-core parallel,
                // so the handoff's "one core at a time" line would be false.
                Text("Toolbox works several files at once on your Mac's fastest cores.")
                    .themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .finished:
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved in \(Self.folderBreadcrumb(model: model))").themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text("Click any file to open it. Changed your mind? Pick a different quality.")
                    .themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .problems:
            Text("Files that failed were not touched at all.").themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .empty:
            EmptyView()
        case .ready:
            PrimaryButton(title: Self.startTitle(model: model), isEnabled: model.canStart, action: onStart)
        case .working:
            SecondaryButton(title: "Cancel", action: onCancel)
        case .finished:
            HStack(spacing: Theme.Spacing.small) {
                SecondaryButton(title: "Show in Finder", icon: Image(systemName: "folder"), action: onShowInFinder)
                SecondaryButton(title: "Change quality", action: onChangeQuality)
                PrimaryButton(title: "Add More", action: onAddMore)
            }
        case .problems:
            HStack(spacing: Theme.Spacing.small) {
                if Self.showsStart(state: state, canStart: model.canStart) {
                    SecondaryButton(title: Self.startTitle(model: model), action: onStart)
                }
                PrimaryButton(title: "Add More", action: onAddMore)
            }
        }
    }

    /// Whether this footer offers Start at all. Screen 03 always does (disabled when refused — the
    /// button IS that screen's point). Screen 10 does too whenever the batch still has runnable
    /// work: Add More on a batch carrying an unresolved failure keeps the screen on `.problems`
    /// (`QueueView.screenState` — a clean pending row never launders a failure away), so without
    /// this the added row would sit there with an estimate and no control on screen that calls
    /// `compress()`. Spec §7's "the batch keeps going": problems never block the rest.
    ///
    /// Additive, never a re-styling: with nothing runnable this renders exactly DESIGN.md §10's
    /// footer ("Files that failed were not touched at all." + `PrimaryButton` "Add More"). The
    /// composite state — problems AND runnable rows — only exists because §7's Add More creates
    /// it; the handoff has no depiction of it, so this is a recorded divergence (DESIGN.md §11,
    /// "Problems footer... gains a secondary Start"; DECISIONS 2026-07-31), not a design-sanctioned
    /// one — Start joins as the SecondaryButton so screen 10 keeps its one filled CTA.
    ///
    /// The one production call site (`trailing`'s `.problems` arm) always passes `state: .problems`
    /// — screen 03's own Start button is unconditional in `trailing`'s `.ready` arm and never asks
    /// this function. `default` covers every other state honestly (no Start) rather than an
    /// exhaustive per-case claim nothing else consults.
    static func showsStart(state: QueueScreenState, canStart: Bool) -> Bool {
        switch state {
        case .problems: return canStart
        default: return false
        }
    }

    // MARK: pure, testable copy

    /// "48.2 MB → about 12.6 MB" from every still-pending row's own input size and estimate — a
    /// row already `.done`/`.failed` (Add More on a finished batch, spec §7) contributed nothing
    /// last run and won't run again from this Start, so it is excluded from both the sum and the
    /// denominator here, not just the sum: counting it in `before`/`predicted` while measuring
    /// completeness against `model.jobs.count` would silently fall through to the honest-but-vague
    /// "total" form on every mixed done+pending screen.
    static func readyHeadline(model: QueueViewModel) -> String {
        let pending = model.pendingJobs
        var before = 0, predicted = 0, counted = 0
        for job in pending {
            guard let size = QueueByteFormat.size(of: job.url) else { continue }
            before += size
            if let estimate = job.estimate {
                predicted += estimate.predictedBytes
                counted += 1
            }
        }
        guard before > 0 else { return "Ready to start" }
        guard counted == pending.count else { return "\(QueueByteFormat.string(before)) total" }
        return "\(QueueByteFormat.string(before)) \u{2192} about \(QueueByteFormat.string(predicted))"
    }

    /// Screen 03's subline: the divergence note (DESIGN.md §9 04c) whenever any row has its
    /// own per-file settings, else the plain originals-are-safe reassurance. Only the singular
    /// wording is pinned by the handoff; a truthful plural is a recorded divergence.
    static func readySubline(model: QueueViewModel) -> String {
        // `differsFromBatch`, not a count of `overrides` entries: a stored field the batch has
        // since floored away changes nothing about the run, and a footer line announcing a
        // divergence that no longer exists is the same lie the row's mark used to tell.
        let overridden = model.jobs.filter { model.differsFromBatch($0.id) }.count
        guard overridden > 0 else { return "Your originals stay exactly where they are." }
        if overridden == 1 {
            return "One file has its own settings, so its estimate differs from the batch."
        }
        return "\(overridden) files have their own settings, so their estimates differ from the batch."
    }

    /// While `canStart` is refused by an in-flight update (spec §6.10's other mutual-exclusion
    /// direction), the ordinary batch caption would read as live when it can't be pressed. Honest
    /// short copy — a recorded divergence, since the handoff has no line for this state.
    static func startTitle(model: QueueViewModel) -> String {
        if model.isUpdatingNow { return "Updating\u{2026}" }
        // `healthyQueuedCount`, never `pendingCount`: the latter counts every queued/analysing row,
        // including an unresolved problem row (locked/missing/unreadable) that `compress()` never
        // actually runs — this caption must count the same rows the run does.
        let queued = model.healthyQueuedCount, armed = model.armedCount
        if queued > 0, armed > 0 { return "Compress \(queued) \u{00B7} Recompress \(armed)" }
        if armed > 0 { return "Recompress \(QueueByteFormat.count(armed, "PDF"))" }
        return "Start"
    }

    /// "N MB saved so far" — never "0 MB saved" (spec §6.3's forbidden string): an all-OCR batch
    /// (or one still too early to have shipped a compressed row) reads the searchable count
    /// instead (`testAllOCRBatchFooterNeverSaysZeroSaved`).
    static func workingHeadline(model: QueueViewModel) -> String {
        let saved = model.batchProgress?.savedSoFarBytes ?? 0
        if saved > 0 { return "\(QueueByteFormat.string(saved)) saved so far" }
        let searchable = model.searchableRowCount
        guard searchable > 0 else { return "Working…" }
        return "\(QueueByteFormat.count(searchable, "file")) made searchable so far"
    }

    /// The last two path components ("Documents › Contracts") of the save destination, or the
    /// first queued row's own folder when nothing was overridden — mirrors `HistoryStore`'s own
    /// nil-folder resolution (a batch with no destination delivers each file beside itself).
    static func folderBreadcrumb(model: QueueViewModel) -> String {
        let folder = model.outputFolder ?? model.jobs.first?.url.deletingLastPathComponent()
        guard let folder else { return "its original folder" }
        let components = folder.pathComponents.filter { $0 != "/" }
        let tail = components.suffix(2)
        return tail.isEmpty ? folder.lastPathComponent : tail.joined(separator: " \u{203A} ")
    }
}

#Preview("Footer – Ready") {
    QueueFooterView(model: QueueViewModel(), state: .ready,
                    onStart: {}, onCancel: {}, onShowInFinder: {}, onChangeQuality: {}, onAddMore: {})
        .frame(width: 900)
}
