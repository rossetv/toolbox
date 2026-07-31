// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The window's top strip across every non-empty screen state: screen 03's title + verb chips +
/// save-destination row, screen 05's working title + progress bar, and screens 06/10's big
/// finished/problems headlines. Owns the `⋯` button and its three-item menu (Recent batches…,
/// Where files are saved…, About Toolbox) in every state that shows it.
struct QueueHeaderView: View {
    @ObservedObject var model: QueueViewModel
    let state: QueueScreenState

    let onAdd: () -> Void
    let onClear: () -> Void
    let onChooseFolder: () -> Void
    let onRecentBatches: () -> Void
    let onAbout: () -> Void
    let onCancel: () -> Void

    /// Owned by `QueueView`, not here: the rows area's dim (spec §7, DESIGN.md §9 04/04b —
    /// "the queue behind dims to 40% while open") needs this same open state, and a sibling
    /// view can only read it if it isn't buried in this view's own `@State`.
    @Binding var qualityPresented: Bool
    @Binding var ocrPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringEllipsis = false
    @State private var isHoveringDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // "3 files" → "Working on 3 files" → "32.6 MB lighter" is a different title row each
            // time, not edited copy: each settles down from a little above as the last fades, the
            // handoff's own `landHead`. The animation is `QueueView`'s, scoped to `screenState`.
            titleRow
                .transition(.opacity.combined(with: .offset(y: -8)))
            if state == .ready {
                HStack(spacing: 8) {
                    VerbChip(title: "Compress", suffix: model.compressOn ? model.preset.title : nil,
                             isOn: model.compressOn, icon: Image(systemName: "arrow.down.right.and.arrow.up.left"),
                             toggle: { model.compressOn.toggle() },
                             openOptions: model.compressOn ? { qualityPresented = true } : nil)
                        // Anchored to the chip itself, not the header's full-width container: a
                        // `.popover` attaches to whatever view carries the modifier, so leaving it
                        // on the outer `VStack` (below) opened the popover centred in the window
                        // rather than pinned to the Compress chip (DESIGN.md §9 04).
                        .popover(isPresented: $qualityPresented) { QualityPopover(model: model) }
                    VerbChip(title: "OCR", suffix: model.ocrOn ? ocrLanguageDisplay : nil,
                             isOn: model.ocrOn, icon: Image(systemName: "doc.text.magnifyingglass"),
                             toggle: { model.ocrOn.toggle() },
                             openOptions: model.ocrOn ? { ocrPresented = true } : nil)
                    Spacer(minLength: Theme.Spacing.small)
                    saveDestinationMenu
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if state == .working, let progress = model.batchProgress {
                CapsuleProgressBar(fraction: progress.fraction)
                    // The bar takes the chips' place as Start is pressed: it grows out of the
                    // hairline rather than appearing at full height.
                    .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .leading)))
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, 20)
        .padding(.bottom, state == .ready ? 14 : 16)
        .popover(isPresented: $ocrPresented) { OCRPopover(model: model) }
    }

    @ViewBuilder
    private var titleRow: some View {
        switch state {
        case .empty: EmptyView()
        case .ready: readyTitleRow
        case .working: workingTitleRow
        case .finished: bigHeadline(kind: .finished, headline: finishedHeadline, subtitle: finishedSubtitle)
        case .problems: bigHeadline(kind: .warn, headline: problemsHeadline, subtitle: problemsSubtitle)
        }
    }

    // MARK: Ready (screen 03)

    private var readyTitleRow: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(QueueByteFormat.count(model.pendingCount, "file"))
                .themeFont(.windowHeadline).foregroundStyle(Theme.Colors.text)
            if totalInputBytes > 0 {
                Text(QueueByteFormat.string(totalInputBytes))
                    .themeFont(.body13).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.small)
            LinkButton(title: "+ Add", action: onAdd)
            if model.canClearFinished {
                LinkButton(title: "⊗ Clear", action: onClear)
            }
            ellipsisMenu
        }
    }

    /// Only still-pending rows: a `.done`/`.failed` row that shares this screen with fresh ones
    /// (Add More on a finished batch, spec §7) already ran and contributes nothing to a figure
    /// meant to describe what Start is about to do.
    private var totalInputBytes: Int {
        model.pendingJobs.compactMap { QueueByteFormat.size(of: $0.url) }.reduce(0, +)
    }

    private var ocrLanguageDisplay: String {
        guard let code = model.ocrOptions.languages.first,
              let entry = OCROptions.curatedLanguages.first(where: { $0.code == code }) else {
            return "English"
        }
        return entry.display
    }

    @ViewBuilder
    private var saveDestinationMenu: some View {
        let destinationLabel = model.outputFolder?.lastPathComponent ?? "Saving beside the originals"
        Menu {
            Button("Beside the originals") { model.outputFolder = nil }
            Button("Choose folder…", action: onChooseFolder)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 11))
                Text(destinationLabel).themeFont(.body13)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            // Handoff: `transition:color .15s`, hovering `text3` → `text2`.
            .foregroundStyle(isHoveringDestination ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .continuousHover($isHoveringDestination)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringDestination)
        .accessibilityLabel("Save destination, \(destinationLabel)")
        .accessibilityHint("Opens a menu to change where files are saved")
    }

    // MARK: Working (screen 05)

    private var workingTitleRow: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Working on \(QueueByteFormat.count(model.jobs.count, "file"))")
                .themeFont(.windowHeadline).foregroundStyle(Theme.Colors.text)
            if let progress = model.batchProgress {
                Text(workingStatusText(progress))
                    .themeFont(.body13).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.small)
            LinkButton(title: "Cancel", action: onCancel)
        }
    }

    private func workingStatusText(_ progress: BatchProgress) -> String {
        // This text renders only on screen 05 (`state == .working`), so the batch is by
        // definition not finished yet — a row's own live fraction can round to 100 a beat before
        // its terminal state lands (e.g. OCR's last-page report), and the honest-progress rule
        // (spec §6.8) forbids a done-claim ahead of reality.
        let percent = min(99, Int((progress.fraction * 100).rounded()))
        guard let eta = progress.etaSeconds else { return "\(percent)%" }
        return "\(percent)% · about \(QueueByteFormat.count(eta, "second")) left"
    }

    // MARK: Finished / Problems big headlines (composed here directly — no handoff component)

    private enum HeadlineKind { case finished, warn }

    @ViewBuilder
    private func bigHeadline(kind: HeadlineKind, headline: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            headlineGlyph(kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).themeFont(.windowHeadline).foregroundStyle(Theme.Colors.text)
                Text(subtitle).themeFont(.body13).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.small)
            ellipsisMenu
        }
    }

    /// The filled disc + glyph screen 06/10 use — deliberately NOT `StatusIndicator`, whose
    /// `.warn` case is a different (outline) shape reserved for row-level degraded outcomes; see
    /// its doc comment.
    private func headlineGlyph(_ kind: HeadlineKind) -> some View {
        let (tint, symbol): (Color, String) = kind == .finished
            ? (Theme.Colors.success, "checkmark") : (Theme.Colors.warn, "exclamationmark")
        return HeadlineGlyphPop(tint: tint, symbol: symbol)
    }

    /// DESIGN.md §8's `checkPop` (scale 0.4→1.16→1, 0.45s) — the header disc, undelayed; the row
    /// checks (`StatusIndicator.filledCheck`) carry the pinned 0.25s delay behind this one.
    private struct HeadlineGlyphPop: View {
        let tint: Color
        let symbol: String

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hasAppeared = false

        var body: some View {
            ZStack {
                Circle().fill(tint)
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.4)
            .onAppear {
                guard !reduceMotion else { hasAppeared = true; return }
                withAnimation(.spring(response: Theme.Motion.checkPop, dampingFraction: 0.58)) { hasAppeared = true }
            }
        }
    }

    private var finishedHeadline: String {
        let saved = model.batchProgress?.savedSoFarBytes ?? 0
        if saved > 0 { return "\(QueueByteFormat.string(saved)) lighter" }
        // All-OCR / no-savings batch (spec §6.3): never "0 MB lighter" — the searchable count
        // carries the headline instead.
        let searchable = model.searchableRowCount
        return searchable > 0 ? "\(QueueByteFormat.count(searchable, "file")) now searchable" : "Already optimised"
    }

    private var finishedSubtitle: String {
        var before = 0, after = 0, files = 0
        for job in model.jobs {
            guard let sizes = model.displayedSizes(for: job) else { continue }
            before += sizes.before; after += sizes.after; files += 1
        }
        let totals = files > 0 ? "\(QueueByteFormat.string(before)) → \(QueueByteFormat.string(after)) across \(QueueByteFormat.count(files, "file"))" : QueueByteFormat.count(model.jobs.count, "file")
        let searchable = model.searchableRowCount
        guard searchable > 0 else { return "\(totals)." }
        return "\(totals). \(searchable == 1 ? "One is" : "\(searchable) are") now searchable."
    }

    private var problemsHeadline: String {
        Self.problemsHeadline(jobs: model.jobs, inspections: model.inspections, skipped: model.skippedRows)
    }

    /// Delivered-of-total (spec §7): the numerator counts only rows that actually delivered
    /// (terminal `.done`) — a `.failed` row never ran to completion and an unresolved problem row
    /// never joined the run at all, so neither counts as "done" even though the batch is over.
    /// Threads the real `inspections`/`skipped` through `QueueRowPartition.classify` — the shared
    /// predicate, not synthesised empty state — even though `.delivered` ignores both today: a
    /// future change to what "delivered" means only has this one call site to get right.
    static func problemsHeadline(jobs: [ToolJob], inspections: [ToolJob.ID: RowInspection] = [:],
                                 skipped: Set<ToolJob.ID> = []) -> String {
        let done = jobs.filter { QueueRowPartition.classify(job: $0, inspections: inspections, skipped: skipped) == .delivered }.count
        return "\(done) of \(jobs.count) files done"
    }

    private var problemsSubtitle: String {
        Self.problemsSubtitle(jobs: model.jobs, inspections: model.inspections,
                              skipped: model.skippedRows,
                              savedSoFarBytes: model.batchProgress?.savedSoFarBytes ?? 0)
    }

    /// Rows needing the user's attention: a run-time failure, or an add-time problem
    /// (locked/missing/unreadable), that was never skipped or fixed — mirrors
    /// `QueueView.screenState`'s own `hasFailed`/`hasUnresolvedProblem` via the same shared
    /// `QueueRowPartition.classify`, so a skipped failed/problem row (resolved-by-skip) drops out
    /// of this count exactly as it drops out of `.problems`, never stranding the header's claim.
    static func problemsSubtitle(jobs: [ToolJob], inspections: [ToolJob.ID: RowInspection],
                                 skipped: Set<ToolJob.ID> = [], savedSoFarBytes: Int) -> String {
        let needAttention = jobs.filter { job in
            switch QueueRowPartition.classify(job: job, inspections: inspections, skipped: skipped) {
            case .failedActionable, .problemUnresolved: return true
            case .delivered, .failedSkipped, .problemSkipped, .cleanPending, .cleanSkipped, .transient: return false
            }
        }.count
        let savedPart = savedSoFarBytes > 0 ? "\(QueueByteFormat.string(savedSoFarBytes)) saved. " : ""
        return needAttention == 1 ? "\(savedPart)One file needs something from you."
                                  : "\(savedPart)\(needAttention) files need something from you."
    }

    private var ellipsisMenu: some View {
        Menu {
            Button("Recent batches…", action: onRecentBatches)
            Button("Where files are saved…", action: onChooseFolder)
            Button("About Toolbox", action: onAbout)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHoveringEllipsis ? Theme.Colors.text : Theme.Colors.textSecondary)
                .frame(width: 28, height: 28)
                // Handoff: `transition:background .15s`, the fill deepening on hover. A `Menu`
                // has no `configuration.isPressed` to read, so this and `saveDestinationMenu`
                // are hover-only — the two native `Menu`s (DESIGN.md §4.3) are the only
                // interactive surfaces in the app without a press state.
                .background(isHoveringEllipsis ? Theme.Colors.fill : Theme.Colors.background,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .continuousHover($isHoveringEllipsis)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringEllipsis)
        .accessibilityLabel("More")
    }
}

#Preview("Header – Ready") {
    QueueHeaderView(model: QueueViewModel(), state: .ready,
                    onAdd: {}, onClear: {}, onChooseFolder: {}, onRecentBatches: {}, onAbout: {}, onCancel: {},
                    qualityPresented: .constant(false), ocrPresented: .constant(false))
        .frame(width: 900)
        .background(Theme.Colors.surface)
}
