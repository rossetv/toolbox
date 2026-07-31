// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The window's top strip across every non-empty screen state: screen 03's title + verb chips +
/// save-destination row, screen 05's working title + progress bar, and screens 06/10's big
/// finished/problems headlines. Owns the `⋯` button and its three-item menu (spec P-A task:
/// Recent batches…, Where files are saved…, About Toolbox) in every state that shows it.
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
        .popover(isPresented: $qualityPresented) { QualityPopover(model: model) }
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
            Text("\(model.pendingCount) file\(model.pendingCount == 1 ? "" : "s")")
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
        model.jobs.filter { job in
            switch job.state {
            case .queued, .analysing: return true
            case .running, .done, .failed: return false
            }
        }.compactMap { QueueByteFormat.size(of: $0.url) }.reduce(0, +)
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
            Text("Working on \(model.jobs.count) file\(model.jobs.count == 1 ? "" : "s")")
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
        let percent = Int((progress.fraction * 100).rounded())
        guard let eta = progress.etaSeconds else { return "\(percent)%" }
        return "\(percent)% · about \(eta) second\(eta == 1 ? "" : "s") left"
    }

    // MARK: Finished / Problems big headlines (P-A composition — no handoff component; see
    // `QueueComponents.swift`'s per-screen map)

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
        return ZStack {
            Circle().fill(tint)
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }

    private var finishedHeadline: String {
        let saved = model.batchProgress?.savedSoFarBytes ?? 0
        if saved > 0 { return "\(QueueByteFormat.string(saved)) lighter" }
        // All-OCR / no-savings batch (spec §6.3): never "0 MB lighter" — the searchable count
        // carries the headline instead.
        let searchable = searchableRowCount
        return searchable > 0 ? "\(searchable) file\(searchable == 1 ? "" : "s") now searchable" : "Already optimised"
    }

    private var finishedSubtitle: String {
        var before = 0, after = 0, files = 0
        for job in model.jobs {
            guard let sizes = model.displayedSizes(for: job) else { continue }
            before += sizes.before; after += sizes.after; files += 1
        }
        let totals = files > 0 ? "\(QueueByteFormat.string(before)) → \(QueueByteFormat.string(after)) across \(files) file\(files == 1 ? "" : "s")" : "\(model.jobs.count) file\(model.jobs.count == 1 ? "" : "s")"
        let searchable = searchableRowCount
        guard searchable > 0 else { return "\(totals)." }
        return "\(totals). \(searchable == 1 ? "One is" : "\(searchable) are") now searchable."
    }

    /// Rows OCR made searchable (mirrors `HistoryStore`'s own `searchableCount` derivation,
    /// binding carry #1: the STORE's flag, never `job.state`'s outcome, which is stale after a
    /// re-run and disagrees by design on the all-lossy path).
    private var searchableRowCount: Int {
        model.jobs.filter { model.versions(for: $0)?.searchableByCard[.shipped] == true }.count
    }

    private var problemsHeadline: String { Self.problemsHeadline(jobs: model.jobs) }

    /// Delivered-of-total (spec §7): the numerator counts only rows that actually delivered
    /// (terminal `.done`) — a `.failed` row never ran to completion and an unresolved problem row
    /// never joined the run at all, so neither counts as "done" even though the batch is over.
    static func problemsHeadline(jobs: [ToolJob]) -> String {
        let done = jobs.filter { QueueRowPartition.classify(job: $0, inspections: [:], skipped: []) == .delivered }.count
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
            Button("Recent Batches…", action: onRecentBatches)
            Button("Where Files Are Saved…", action: onChooseFolder)
            Button("About Toolbox", action: onAbout)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHoveringEllipsis ? Theme.Colors.text : Theme.Colors.textSecondary)
                .frame(width: 28, height: 28)
                // Handoff: `transition:background .15s`, the fill deepening on hover. A `Menu`
                // has no `configuration.isPressed` to read, so this control is hover-only — the
                // one interactive surface in the app without a press state (DESIGN.md §11).
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
