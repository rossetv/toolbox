// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// Change quality (handoff screen 08), opened from the Finished screen: three preset cards
/// priced from the CURRENT rows, and a per-row mechanism line for whichever preset is picked.
///
/// Picking a card sets `model.preset` — the SAME batch preset the Ready screen's Quality
/// popover writes — which is what makes the row list below re-arm live: `recompressState`/
/// `recompressPrediction` already key off `effectivePreset(for:)`, so this sheet previews by
/// genuinely (if reversibly) moving the batch preset, never a second, parallel "candidate" of
/// its own. Picking a card also clears the per-row PRESET override on every included row, because
/// `effectivePreset` — not the batch preset — is what a row actually arms against, so without that
/// an overridden row silently ignored the whole sheet. The restore is structural, not per-button:
/// `onDisappear` puts `model.preset`, `model.armedExclusions` AND `model.overrides` back to
/// whatever they were before the sheet opened on EVERY exit — Cancel, Escape, the window closing,
/// anything else — unless the confirm action has already handed off to `Self.confirm`.
struct ChangeQualitySheet: View {
    @ObservedObject var model: QueueViewModel
    /// Presented as an in-window overlay (see `QueueView`'s overlay call site), so closing is a
    /// caller-supplied closure — `@Environment(\.dismiss)` has no presentation to dismiss here.
    let onClose: () -> Void
    @State private var initialPreset: CompressPreset
    /// Snapshot of `model.armedExclusions` at sheet open — the sibling of `initialPreset`: "Choose
    /// which files…" writes exclusions onto the SAME view-model the preset preview lives on, so it
    /// needs the identical structural restore (spec §7 scopes the checked subset to THE RE-RUN).
    @State private var initialExclusions: Set<ToolJob.ID>
    /// Snapshot of `model.overrides` at sheet open — the third member of the restore set, and the
    /// one that makes the sheet's promise true: a row carrying its OWN preset override arms against
    /// that preset (`recompressState` reads `effectivePreset`), so moving the batch preset alone
    /// left such a row reading "Already optimised — nothing to change" and the CTA disabled, while
    /// the cards above it priced a saving. Applying a quality here clears the per-row PRESET (its
    /// OCR/rebuild fields survive) for every included row, which is what "Applies to all {n} files"
    /// says on the tin; every exit that does not start work puts the snapshot back.
    @State private var initialOverrides: [ToolJob.ID: RowOverride]
    @State private var showingFileChoice = false
    /// Set the moment the confirm action hands off to `Self.confirm` — the ONLY thing that stops
    /// `onDisappear` restoring `initialPreset`/`initialExclusions`. Every other exit (Cancel,
    /// Escape, the window closing, anything else) leaves this false, so the restore fires
    /// structurally rather than depending on which button happened to be pressed.
    @State private var confirmed = false

    init(model: QueueViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _initialPreset = State(initialValue: model.preset)
        _initialExclusions = State(initialValue: model.armedExclusions)
        _initialOverrides = State(initialValue: model.overrides)
    }

    var body: some View {
        SheetChrome(width: 640) {
            VStack(alignment: .leading, spacing: 16) {
                header
                cards
                rowList
                footer
            }
            .padding(20)
        }
        // Also on open, not only when a card is tapped: the sheet opens with the batch preset
        // already selected, so a row whose override points elsewhere would sit there reading
        // "Already optimised — nothing to change" against a card that says it saves 145 KB, and
        // only start telling the truth once some card was clicked.
        .onAppear { applySelectionToIncludedRows() }
        .onDisappear {
            if !confirmed {
                model.preset = initialPreset
                model.setArmedExclusions(initialExclusions)
                Self.restoreOverrides(initialOverrides, model: model)
            }
        }
    }

    /// Drop the per-row PRESET override on every row this sheet's selection applies to, so the
    /// chosen quality actually reaches them. Called from the cards and from "Choose which files…"
    /// — ticking a row back in has to clear its override too, or that row alone would keep
    /// quietly ignoring the batch. Rows left unticked keep their overrides untouched.
    private func applySelectionToIncludedRows() {
        for job in eligibleJobs where !model.armedExclusions.contains(job.id) {
            guard var override = model.overrides[job.id], override.preset != nil else { continue }
            override.preset = nil
            model.setOverride(override, for: job.id)
        }
    }

    /// Put a snapshot of the overrides back, key by key — `setOverride` is the only writer, so the
    /// reservations and re-pricing it owns follow the restore exactly as they followed the change.
    /// Rows added while the sheet was open are covered: a key present now but absent from the
    /// snapshot restores to `nil`.
    static func restoreOverrides(_ snapshot: [ToolJob.ID: RowOverride], model: QueueViewModel) {
        for id in Set(snapshot.keys).union(model.overrides.keys) {
            model.setOverride(snapshot[id], for: id)
        }
    }

    // MARK: rows

    /// Every finished row that could be recompressed at all — a row whose compress leg never ran
    /// or was skipped (a rescue, an OCR-only delivery) has nothing for this sheet to price or
    /// re-run (spec §6.5). Mirrors `recompressState`'s own arming rule: `.compressed`/`.noGain`
    /// both stay eligible even though a `.noGain` row also has no `shipped` version on record.
    private var eligibleJobs: [ToolJob] {
        model.jobs.filter { job in
            guard case .done(let outcome) = job.state else { return false }
            return Self.isEligible(compress: outcome.compress, hasVersionsRecorded: model.versions(for: job) != nil)
        }
    }

    /// The pure eligibility predicate `eligibleJobs` filters on (MARK: pure logic below) —
    /// extracted so it can be asserted without driving a live view/model.
    static func isEligible(compress: CompressOutcome?, hasVersionsRecorded: Bool) -> Bool {
        switch compress {
        case nil, .skipped: return false
        case .compressed, .noGain: break
        }
        return hasVersionsRecorded
    }

    private func summary(for job: ToolJob) -> RowSummary? {
        guard let row = model.versions(for: job) else { return nil }
        return RowSummary(
            currentBytes: row.shipped?.bytes ?? row.originalBytes,
            ownPreset: row.rowPreset,
            prediction: { model.recompressPrediction(for: job, at: $0) },
            isExcluded: model.armedExclusions.contains(job.id),
            isFutile: { model.isFutileAttempt(job.id, at: $0) })
    }

    // MARK: header

    /// Priced off `eligibleJobs`, not the exclusion-filtered subset: "Choose which files…" must
    /// list every row you may untick, excluded ones included.
    private var header: some View {
        let includedCount = eligibleJobs.filter { !model.armedExclusions.contains($0.id) }.count
        return HStack(alignment: .firstTextBaseline) {
            SheetTitleRow(title: "Different quality for these \(QueueByteFormat.count(eligibleJobs.count, "file"))",
                         caption: "Applies to all \(QueueByteFormat.count(includedCount, "file"))")
            // Anchored to the link itself, never to the sheet: a `.popover` tails whichever view
            // carries the modifier, and on the sheet's root (a window-filling ZStack) it opened
            // centred in nowhere — the same defect the row gear had.
            LinkButton(title: "Choose which files…") { showingFileChoice = true }
                .popover(isPresented: $showingFileChoice) { fileChoicePopover }
        }
    }

    // MARK: option cards

    private var cards: some View {
        let summaries = eligibleJobs.compactMap(summary(for:))
        let current = Self.total(summaries, at: nil)
        return HStack(spacing: 8) {
            ForEach(CompressPreset.allCases) { preset in
                let value = Self.total(summaries, at: preset)
                let delta = Self.delta(current: current, candidate: value,
                                       presetIsMaximumQuality: preset == .maximumQuality)
                OptionCard(
                    title: preset.title,
                    value: QueueByteFormat.string(value),
                    caption: delta.text,
                    captionTone: delta.tone.optionCardTone,
                    isSelected: model.preset == preset,
                    action: {
                        model.preset = preset
                        applySelectionToIncludedRows()
                    }
                )
            }
        }
    }

    // MARK: per-row mechanism lines

    private var rowList: some View {
        VStack(spacing: 2) {
            ForEach(eligibleJobs) { job in
                if let row = model.versions(for: job) {
                    let state = model.recompressState(for: job)
                    let currentBytes = row.shipped?.bytes ?? row.originalBytes
                    // Same preset `recompressState` itself armed against — `model.effectivePreset`,
                    // not the batch's `model.preset` — so an overridden row's shown target/DPI can
                    // never disagree with the preset its `.armed` state actually names.
                    let rowPreset = model.effectivePreset(for: job.id)
                    let target = Self.rowTargetBytes(
                        state: state, currentBytes: currentBytes,
                        prediction: model.recompressPrediction(for: job, at: rowPreset))
                    QueueRow(name: job.url.lastPathComponent,
                            meta: Self.mechanismLine(
                                state: state, preset: rowPreset,
                                measuredRate: model.measuredPageRate(for: job.id),
                                pageCount: model.inspections[job.id]?.pageCount,
                                isExcluded: model.armedExclusions.contains(job.id))) {
                        QueueRowSizeColumn(
                            current: QueueByteFormat.string(currentBytes),
                            target: QueueByteFormat.string(target),
                            sameSize: Self.rowIsUnchanged(state),
                            // only-08.html: a changed row's arrow + target read accent here, not
                            // the plain textSecondary the Ready screen's own rows use.
                            changedColor: Theme.Colors.accent)
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        let summaries = eligibleJobs.compactMap(summary(for:))
        let current = Self.total(summaries, at: nil)
        let predicted = Self.total(summaries, at: model.preset)
        let canSwitch = Self.canSwitch(eligibleJobs.map { model.recompressState(for: $0) })
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(QueueByteFormat.string(current)) → about \(QueueByteFormat.string(predicted))")
                    .themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text("Rebuilt from your originals — the files you have now stay until the new ones land.")
                    .themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.small)
            SecondaryButton(title: "Cancel", action: onClose)
            PrimaryButton(title: "Switch to \(model.preset.title)", isEnabled: canSwitch) {
                let rows = eligibleJobs
                let fallback = initialPreset
                let fallbackExclusions = initialExclusions
                let fallbackOverrides = initialOverrides
                confirmed = true
                Task {
                    await Self.confirm(rows: rows, model: model, fallback: fallback,
                                       fallbackExclusions: fallbackExclusions,
                                       fallbackOverrides: fallbackOverrides)
                }
                onClose()
            }
        }
    }

    private var fileChoicePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(eligibleJobs) { job in
                CheckRow(title: job.url.lastPathComponent,
                        isChecked: Binding(
                            get: { !model.armedExclusions.contains(job.id) },
                            set: {
                                model.setArmedExclusion(!$0, for: job.id)
                                applySelectionToIncludedRows()
                            }))
            }
        }
        .padding(14)
        .frame(minWidth: 240)
    }

    // MARK: pure logic (PopoverLogicTests)

    struct RowSummary {
        let currentBytes: Int
        /// The row's actual, historical preset (`RowVersions.rowPreset`) — deliberately NOT
        /// `effectivePreset(for:)`, which tracks the live (previewed) batch selection this sheet
        /// is busy changing.
        let ownPreset: CompressPreset
        let prediction: (CompressPreset) -> Int?
        let isExcluded: Bool
        /// Whether the row already came back with no saving at a given candidate preset
        /// (`QueueViewModel.isFutileAttempt`) — the same closed-set test `recompressState` (and so
        /// `rowList`/`rowTargetBytes`) checks, so the card/footer totals below cannot count a
        /// saving for a row the per-row list shows as "nothing to change".
        let isFutile: (CompressPreset) -> Bool
    }

    /// The card total for one candidate preset — `nil` reads "the row's current preset" (the
    /// "what you have" baseline). A row already at the candidate, or proven futile there, uses its
    /// own recorded bytes (exact); an excluded row never moves; everything else falls back to its
    /// current bytes when no confident prediction exists, so no row ever vanishes from the total.
    static func total(_ rows: [RowSummary], at preset: CompressPreset?) -> Int {
        rows.reduce(0) { sum, row in
            guard let preset, !row.isExcluded, row.ownPreset != preset, !row.isFutile(preset) else {
                return sum + row.currentBytes
            }
            return sum + (row.prediction(preset) ?? row.currentBytes)
        }
    }

    enum DeltaTone: Equatable {
        case success, muted, plain
        var optionCardTone: OptionCard.Tone {
            switch self {
            case .success: return .success
            case .muted: return .muted
            case .plain: return .plain
            }
        }
    }

    /// The card's caption beneath its total (screen 08): the currently-active total reads "what
    /// you have"; a smaller total reads its saving in green; a larger one reads a plain delta —
    /// except Maximum quality, whose larger total always reads its aspirational "for printing"
    /// tagline (the one preset in this trio that is never chosen to save space).
    static func delta(current: Int, candidate: Int, presetIsMaximumQuality: Bool) -> (text: String, tone: DeltaTone) {
        let diff = candidate - current
        if diff == 0 { return ("what you have", .muted) }
        if diff < 0 { return ("\(QueueByteFormat.string(-diff)) less", .success) }
        return (presetIsMaximumQuality ? "for printing" : "\(QueueByteFormat.string(diff)) more", .plain)
    }

    /// The row's own mechanism line (spec §6.7's honest-progress rule): armed rows show the
    /// duration only when `measuredRate`/`pageCount` are both known — a row with no measured run
    /// shows the mechanism without fabricating a number. `isExcluded` covers the one `.none` cause
    /// `rowList` can actually reach ("Choose which files…" unticked this row) — distinct from a
    /// genuinely futile row, which the design's "Already optimised" caption does not describe.
    static func mechanismLine(state: QueueViewModel.RowRecompressState, preset: CompressPreset,
                              measuredRate: Double?, pageCount: Int?, isExcluded: Bool = false) -> String {
        if isExcluded { return "Not included" }
        switch state {
        case .armed:
            let mechanism = "Redone from the original at \(preset.imageDPI) DPI"
            guard let measuredRate, let pageCount, pageCount > 0 else { return mechanism }
            let seconds = max(1, Int((measuredRate * Double(pageCount)).rounded()))
            return "\(mechanism) · about \(QueueByteFormat.count(seconds, "second"))"
        case .instantSwitch:
            return "Already on disk — swapped in immediately"
        case .futile, .none:
            return "Already optimised — nothing to change"
        }
    }

    /// Whether a row's recompress state is "nothing to change" (screen 08's grey/no-arrow
    /// rows) — the SAME predicate `mechanismLine` reads for its "Already optimised — nothing
    /// to change" caption, so the subtitle and the size pair can never disagree (the render-08
    /// finding this fixes).
    static func rowIsUnchanged(_ state: QueueViewModel.RowRecompressState) -> Bool {
        switch state {
        case .futile, .none: return true
        case .armed, .instantSwitch: return false
        }
    }

    /// The row's projected size at the current preset selection: pinned to its own current
    /// bytes (no estimator pass) when nothing would actually change, otherwise the prediction
    /// (falling back to current bytes when no confident estimate exists, same as the footer's
    /// `total`).
    static func rowTargetBytes(state: QueueViewModel.RowRecompressState, currentBytes: Int,
                               prediction: Int?) -> Int {
        rowIsUnchanged(state) ? currentBytes : (prediction ?? currentBytes)
    }

    /// The footer CTA is only a genuine switch when at least one eligible row would actually
    /// change (spec §7): every row reading "nothing to change" makes "Switch to X" a no-op that
    /// must not be offered as if it did something.
    static func canSwitch(_ states: [QueueViewModel.RowRecompressState]) -> Bool {
        states.contains { !rowIsUnchanged($0) }
    }

    /// The footer CTA's action (spec §7): for each selected-scope row whose `recompressState` is
    /// `.instantSwitch`, land the parked previous version through the SAME on-disk switch the
    /// versions popover uses (`useVersion`/`VersionStore`) — never a second, bespoke mechanism —
    /// and only then run `compress()` for the rows that actually armed. A mixed batch (some
    /// instant-switch, some armed, some unchanged) honours both mechanisms in one press; unchanged
    /// rows match neither branch and are left exactly alone.
    ///
    /// `compress()` itself refuses to start when `canStart` is false (a switch already in flight,
    /// the updater running, no engine) — a case this button's `isEnabled` (`canSwitch`, which only
    /// checks row states) does not rule out. If nothing actually started — no instant switch
    /// LANDED AND `compress()` was refused — the preview must not stick: `fallback` (the batch
    /// preset from before the sheet opened) is restored so a no-op press leaves no trace, and
    /// `fallbackExclusions` (the exclusion set from before the sheet opened) goes back with it —
    /// the sibling leak this fixes: a no-op press must not narrow the NEXT re-run either.
    ///
    /// "Landed" is load-bearing: `useVersion` can be ATTEMPTED and still fail (a transient store
    /// error keeps the shipped file exactly as it was — see `reportSwitchFailure`), so attempting
    /// it is not evidence anything started. `useVersion` itself now RETURNS whether the switch
    /// landed (review finding, R12) — not every failure arm writes `recompressErrors` (the
    /// missing-shipped-file and stranded-parked-file arms only set `switchFailures`), so inferring
    /// "landed" from that dictionary being nil silently counted those failures as successes.
    ///
    /// Something actually starting is what consumes the exclusion set, not the run finishing:
    /// spec §7 scopes the checked subset to THIS re-run, so once it is under way the whole set is
    /// cleared — a row a completed run already recompressed stops arming on its own (it now
    /// matches its own target), and a row left untouched (excluded, or refused alongside it) is
    /// free to arm again next time the sheet opens, unexcluded, exactly like a fresh preview.
    static func confirm(rows: [ToolJob], model: QueueViewModel, fallback: CompressPreset,
                        fallbackExclusions: Set<ToolJob.ID>,
                        fallbackOverrides: [ToolJob.ID: RowOverride]) async {
        var switchLanded = false
        for job in rows {
            if case .instantSwitch = model.recompressState(for: job) {
                if await model.useVersion(.previous, for: job) {
                    switchLanded = true
                }
            }
        }
        let compressStarted = model.canStart
        if compressStarted {
            model.compress()
        }
        if switchLanded || compressStarted {
            model.setArmedExclusions([])
        } else {
            model.preset = fallback
            model.setArmedExclusions(fallbackExclusions)
            // The third member of the restore set (`initialOverrides`): a refused press must not
            // leave the per-row presets this sheet cleared for its preview stripped for good.
            restoreOverrides(fallbackOverrides, model: model)
        }
    }

}

#Preview("ChangeQualitySheet") {
    ChangeQualitySheet(model: QueueViewModel(engine: nil), onClose: {})
        .frame(width: 900, height: 600)
        .background(Theme.Colors.background)
}
