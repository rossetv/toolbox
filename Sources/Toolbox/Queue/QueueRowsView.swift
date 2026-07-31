// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// Byte formatting shared by the header/rows/footer copy — one place so a figure never reads
/// differently two lines apart.
enum QueueByteFormat {
    static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The scrollable queue list: every row across screens 03 (ready)/05 (working)/06 (finished)/10
/// (problems), one shape (`QueueRow`) whose trailing content and copy this view composes per row
/// from the model (`displayedSizes`/`searchableByCard[.shipped]`, never `job.state`'s
/// `RowOutcome` alone — the outcome is stale after a re-run and disagrees by design on the
/// all-lossy path).
struct QueueRowsView: View {
    @ObservedObject var model: QueueViewModel
    let state: QueueScreenState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var perFileJobID: ToolJob.ID?
    @State private var versionsJobID: ToolJob.ID?

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.jobs) { job in
                    row(for: job)
                        // The handoff lands dropped rows rising into place; a removed row leaves
                        // by shrinking out rather than the list snapping shut under the pointer.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 26)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        ))
                }
                if state == .ready {
                    dropHint
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            // Keyed on the row identities rather than on `model.jobs` itself: the queue mutates
            // from a dozen places across the view model (add, remove, skip, clearFinished, the
            // run's own state writes), and animating in the view layer keeps every one of them
            // from having to remember a `withAnimation`. Progress writes don't change the id
            // list, so a running batch doesn't re-trigger this.
            .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: model.jobs.map(\.id))
        }
    }

    private var dropHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 11))
            Text("Drop more PDFs anywhere in this window").themeFont(.meta)
        }
        .foregroundStyle(Theme.Colors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.large)
    }

    // MARK: row composition

    @ViewBuilder
    private func row(for job: ToolJob) -> some View {
        let descriptor = Self.describe(job: job, model: model, state: state)
        QueueRow(
            name: job.url.lastPathComponent,
            meta: descriptor.meta,
            metaAccent: descriptor.metaAccent,
            fileURL: job.url,
            emphasis: descriptor.emphasis,
            onOpen: descriptor.canOpen ? { NSWorkspace.shared.open(Self.urlToOpen(for: job, model: model)) } : nil,
            onGear: descriptor.canConfigure ? { perFileJobID = job.id } : nil,
            onRemove: descriptor.canRemove ? { model.remove(job) } : nil,
            versionsCapsuleTitle: descriptor.capsuleTitle,
            isVersionsCapsuleOpen: versionsJobID == job.id,
            onVersionsCapsule: descriptor.capsuleTitle != nil ? { versionsJobID = job.id } : nil
        ) {
            trailing(for: job, descriptor: descriptor)
        }
        .popover(isPresented: Binding(get: { perFileJobID == job.id }, set: { if !$0 { perFileJobID = nil } })) {
            PerFileSettingsPopover(model: model, jobID: job.id)
        }
        .popover(isPresented: Binding(get: { versionsJobID == job.id }, set: { if !$0 { versionsJobID = nil } })) {
            VersionsPopoverContent(model: model, jobID: job.id)
        }
    }

    /// `.active`'s live ETA reads as a plain figure (`.body13`); every other slot's size figure
    /// is the row-name weight (matches the component's own preview gallery).
    private func statusTextFont(_ kind: StatusIndicator.Kind) -> Theme.Typography {
        if case .active = kind { return .body13 }
        return .rowName
    }

    private func statusTextColor(_ kind: StatusIndicator.Kind) -> Color {
        switch kind {
        case .queued, .active, .unchanged: return Theme.Colors.textTertiary
        case .finished, .warn: return Theme.Colors.text
        }
    }

    /// Explicit `AnyView`, not an opaque `some View`: the five branches are genuinely
    /// heterogeneous view types, and erasing here — once, at this one seam — is what lets
    /// `QueueRow<Trailing>`'s generic parameter resolve cleanly instead of the whole call chain
    /// (this method's callers, `QueueRow`'s own modifier chain) fighting over a single opaque type.
    private func trailing(for job: ToolJob, descriptor: RowDescriptor) -> AnyView {
        switch descriptor.trailing {
        case .sizeColumn(let current, let target, let kind, let sameSize):
            let column = QueueRowSizeColumn(current: current, target: target, sameSize: sameSize)
            if let kind {
                return AnyView(HStack(spacing: 9) {
                    column
                    StatusIndicator(kind: kind)
                })
            } else {
                return AnyView(column)
            }
        case .status(let text, let kind):
            return AnyView(HStack(spacing: 9) {
                if let text {
                    Text(text).themeFont(statusTextFont(kind)).foregroundStyle(statusTextColor(kind))
                }
                StatusIndicator(kind: kind)
            })
        case .problem(let primary, let link):
            return AnyView(HStack(spacing: 10) {
                if let primary {
                    SecondaryButton(title: primary.title, action: primary.action)
                }
                if let link {
                    LinkButton(title: link.title, action: link.action)
                }
            })
        case .problemPair(let first, let second):
            return AnyView(HStack(spacing: 10) {
                if let first {
                    LinkButton(title: first.title, action: first.action)
                }
                if let second {
                    LinkButton(title: second.title, action: second.action)
                }
            })
        case .skipped(let onUndo):
            return AnyView(HStack(spacing: 10) {
                Text("Skipped").themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
                if let onUndo {
                    LinkButton(title: onUndo.title, action: onUndo.action)
                }
            })
        }
    }

    // MARK: pure, testable derivation

    /// One row's presentation, entirely determined by the model — the piece `QueueViewStateTests`
    /// exercises directly (a SwiftUI body cannot be unit-tested; this can).
    struct RowDescriptor: Equatable {
        enum Trailing: Equatable {
            case sizeColumn(current: String, target: String, kind: StatusIndicator.Kind? = nil, sameSize: Bool = false)
            case status(text: String?, kind: StatusIndicator.Kind)
            case problem(primary: RowAction?, link: RowAction?)
            case problemPair(RowAction?, RowAction?)
            case skipped(onUndo: RowAction?)

            static func == (lhs: Trailing, rhs: Trailing) -> Bool {
                switch (lhs, rhs) {
                case (.sizeColumn(let a, let b, let d, let i), .sizeColumn(let e, let f, let h, let j)):
                    return a == e && b == f && d == h && i == j
                case (.status(let a, let b), .status(let c, let d)):
                    return a == c && b == d
                case (.problem(let a, let b), .problem(let c, let d)):
                    return a?.title == c?.title && b?.title == d?.title
                case (.problemPair(let a, let b), .problemPair(let c, let d)):
                    return a?.title == c?.title && b?.title == d?.title
                case (.skipped(let a), .skipped(let b)):
                    return a?.title == b?.title
                default:
                    return false
                }
            }
        }

        /// A named action — equality compares titles only (closures aren't `Equatable`), which is
        /// all a descriptor-shape test needs.
        struct RowAction {
            let title: String
            let action: () -> Void
        }

        let meta: String
        /// `.danger` for a `recompressErrors` note (R12); `.accent` (the `QueueRow` default) for
        /// every other use — e.g. "Its own settings". Nil when the row has no accent text at all.
        var metaAccent: (text: String, colour: Color)? = nil
        var emphasis: QueueRow<AnyView>.Emphasis = .none
        var trailing: Trailing
        var canOpen = false
        var canConfigure = false
        var canRemove = false
        var capsuleTitle: String? = nil

        static func == (lhs: RowDescriptor, rhs: RowDescriptor) -> Bool {
            lhs.meta == rhs.meta
                && lhs.metaAccent?.text == rhs.metaAccent?.text
                && lhs.metaAccent?.colour == rhs.metaAccent?.colour
                && emphasisEqual(lhs.emphasis, rhs.emphasis)
                && lhs.trailing == rhs.trailing && lhs.canOpen == rhs.canOpen
                && lhs.canConfigure == rhs.canConfigure && lhs.canRemove == rhs.canRemove
                && lhs.capsuleTitle == rhs.capsuleTitle
        }

        /// `QueueRow.Emphasis` (`QueueComponents.swift`) has no associated values but was
        /// never declared `Equatable` there — this file cannot add the conformance (out of
        /// scope), so a plain case-by-case comparison stands in for it.
        private static func emphasisEqual(_ a: QueueRow<AnyView>.Emphasis, _ b: QueueRow<AnyView>.Emphasis) -> Bool {
            switch (a, b) {
            case (.none, .none), (.degraded, .degraded),
                 (.problemDanger, .problemDanger), (.problemWarn, .problemWarn):
                return true
            default:
                return false
            }
        }
    }

    /// The file `onOpen`/Return should open: the shipped version when one exists, else whatever
    /// the queue itself delivered, else the original (mirrors the pre-redesign `CompressView`'s
    /// own fallback chain) — the STORE is asked first, since a recompressed no-gain row has a
    /// delivered file while `job.resultURL` stays nil.
    static func urlToOpen(for job: ToolJob, model: QueueViewModel) -> URL {
        model.versions(for: job)?.shipped?.url ?? job.resultURL ?? job.url
    }

    /// Builds one row's descriptor. `model` methods only — never `job.state`'s `RowOutcome` for a
    /// size or a searchability word (the model's values are never stale; the job state's can be).
    static func describe(job: ToolJob, model: QueueViewModel, state: QueueScreenState) -> RowDescriptor {
        switch job.state {
        case .queued, .analysing:
            return describeQueued(job: job, model: model, state: state)
        case .running(let fraction):
            return describeRunning(job: job, model: model, fraction: fraction)
        case .done:
            return describeDone(job: job, model: model, state: state)
        case .failed(let message):
            return describeFailed(job: job, model: model, message: message)
        }
    }

    // MARK: queued / analysing

    private static func describeQueued(job: ToolJob, model: QueueViewModel,
                                       state: QueueScreenState) -> RowDescriptor {
        let inspection = model.inspections[job.id]
        if let problem = inspection?.problem {
            return describeProblem(job: job, model: model, problem: problem, meta: inspection?.metaLine ?? "")
        }
        let meta = inspection?.metaLine ?? "Queued"
        if state == .working {
            // Not yet started while siblings run (screen 05's "Next" queued row).
            let current = job.estimate.map { QueueByteFormat.string($0.predictedBytes) }
                ?? QueueByteFormat.size(of: job.url).map(QueueByteFormat.string) ?? ""
            return RowDescriptor(meta: "Next", trailing: .status(text: current, kind: .queued), canOpen: true)
        }
        // Per-file override (spec §7, DESIGN.md §9 04c): an overridden row's meta gets the
        // accent "Its own settings" — the popover's own "Match the batch" is what clears it.
        let metaAccent: (text: String, colour: Color)? = model.overrides[job.id] != nil
            ? (text: "Its own settings", colour: Theme.Colors.accent) : nil
        guard let estimate = job.estimate, let inputBytes = QueueByteFormat.size(of: job.url) else {
            return RowDescriptor(meta: meta, metaAccent: metaAccent,
                                  trailing: .sizeColumn(current: "—", target: "—"),
                                  canOpen: true, canConfigure: true, canRemove: true)
        }
        let marker = estimate.isFallback ? "~" : "\u{2248}"
        return RowDescriptor(
            meta: meta, metaAccent: metaAccent,
            trailing: .sizeColumn(current: QueueByteFormat.string(inputBytes),
                                  target: "\(marker)\(QueueByteFormat.string(estimate.predictedBytes))"),
            canOpen: true, canConfigure: true, canRemove: true
        )
    }

    /// Locked/moved/unreadable rows (spec §6.6/§7). Password unlock is deferred (D3, non-goal §3):
    /// the locked row gets Skip/Remove only, never an "Enter password…" affordance. "Unreadable"
    /// gets the same Skip/Remove treatment as locked (recorded divergence) — it names a file
    /// that IS present but is not a usable PDF, which "Find it…" (a re-pick for a file that has
    /// MOVED) does not describe; "Moved or renamed" is the one case with an in-app fix, so it
    /// alone gets `.problemWarn` + "Find it…".
    private static func describeProblem(job: ToolJob, model: QueueViewModel,
                                        problem: RowProblem, meta: String) -> RowDescriptor {
        // Skip/Remove/Undo all refuse mid-run (`setSkipped`/`remove`'s own `!isRunning` guards) —
        // same rule as "Find it…" below: the affordance is absent for the run's duration and
        // reappears once it ends, never a silently-refused no-op button.
        let skip = model.isRunning ? nil :
            RowDescriptor.RowAction(title: "Skip", action: { model.setSkipped(true, for: job.id) })
        let remove = model.isRunning ? nil :
            RowDescriptor.RowAction(title: "Remove", action: { model.remove(job) })
        if model.skippedRows.contains(job.id) {
            let undo = model.isRunning ? nil :
                RowDescriptor.RowAction(title: "Undo", action: { model.setSkipped(false, for: job.id) })
            return RowDescriptor(meta: meta, emphasis: .degraded, trailing: .skipped(onUndo: undo))
        }
        switch problem {
        case .missing:
            // `rebind` refuses mid-run (spec §7) — offering "Find it…" then would be a silent
            // no-op, so the affordance is absent for the run's duration and reappears once it ends.
            let findIt = model.isRunning ? nil :
                RowDescriptor.RowAction(title: "Find it…", action: { rebindViaOpenPanel(job, model: model) })
            return RowDescriptor(meta: meta, emphasis: .problemWarn, trailing: .problem(primary: findIt, link: remove))
        case .locked, .unreadable:
            return RowDescriptor(meta: meta, emphasis: .problemDanger, trailing: .problemPair(skip, remove))
        case .compressFailed:
            // Unreachable from add-time inspection — never produced here.
            return RowDescriptor(meta: meta, emphasis: .problemDanger, trailing: .problemPair(skip, remove))
        }
    }

    /// "Find it…": an NSOpenPanel restricted to PDFs, rebinding the row to whatever the user
    /// picks (spec §7 — refused mid-run inside `rebind` itself).
    private static func rebindViaOpenPanel(_ job: ToolJob, model: QueueViewModel) {
        guard let url = FilePicker.choosePDFs().first else { return }
        model.rebind(job.id, to: url)
    }

    // MARK: running

    private static func describeRunning(job: ToolJob, model: QueueViewModel, fraction: Double) -> RowDescriptor {
        let leg = model.legLabel(for: job.id) ?? "Working…"
        let etaText = model.rowETASeconds(for: job.id).map { "\($0)s left" }
        return RowDescriptor(meta: leg, metaAccent: nil, emphasis: .active,
                             trailing: .status(text: etaText, kind: .active(fraction)))
    }

    // MARK: done

    /// `recompressErrors` (`QueueViewModel`) rides beside a `.done` row's own meta rather than
    /// replacing it (R12: an explicit button press — recompress, change-quality re-run, or a
    /// versions-popover switch — never fails silently, and the row's result stays displayed and
    /// openable throughout). `metaAccent` is otherwise unused for a `.done` row, so this is the one
    /// site that needs to know about the dictionary at all.
    private static func describeDone(job: ToolJob, model: QueueViewModel, state: QueueScreenState) -> RowDescriptor {
        var descriptor = describeDoneCore(job: job, model: model, state: state)
        if let message = model.recompressErrors[job.id] {
            descriptor.metaAccent = (text: message, colour: Theme.Colors.danger)
        }
        return descriptor
    }

    private static func describeDoneCore(job: ToolJob, model: QueueViewModel, state: QueueScreenState) -> RowDescriptor {
        guard case .done(let outcome) = job.state else { fatalError("describeDone requires a .done job") }
        let row = model.versions(for: job)
        // Binding carry #1's other edge: a change-quality re-run (`commit()`) never touches
        // `job.state`, so `outcome` can be arbitrarily stale once the STORE has moved on — a row
        // whose first pass cancelled before reading stays `outcome.isDegraded == true` forever,
        // even after a later re-run's OCR leg lands a confirmed-searchable shipped file. A noGain
        // (or verb-off) row gets a store entry too (`ingestCompletedJobs`'s `.noGain`/`nil` arms)
        // — only a `.skipped` compress leg never arms one, per that arm's own note — so this guard
        // does NOT hold because degraded rows lack an entry; it holds because none of the degraded
        // noGain outcomes ever set `searchableByCard[.shipped]` true. Wherever the store DOES hold
        // a confirmed-searchable shipped card, that fact is fresher than any `.cancelled`/
        // `.tooFaint`/`.failed` OCR reading baked into `outcome`, so it wins.
        if outcome.isDegraded && row?.searchableByCard[.shipped] != true {
            return describeDegraded(job: job, model: model, outcome: outcome)
        }
        guard let sizes = model.displayedSizes(for: job) else {
            // No shipped version: a compress-only no-gain row (truly nothing changed), or the
            // noGain+OCR-added sibling (`row` recorded, `shipped` nil — spec §6.5's grey sizes).
            let isSearchable = row?.searchableByCard[.shipped] == true
            let meta = isSearchable ? "Already optimised · made searchable" : "Already optimised"
            // DESIGN.md §9 06 / spec §6.5: a no-op (or OCR-only) finished row shows a grey SIZE
            // PAIR keyed on its actual bytes, no savings claim — the same arrowless same-size
            // treatment the change-quality sheet's nothing-to-change rows use
            // (`QueueRowSizeColumn.sameSize`), not a single figure.
            let sizeText = row.map { QueueByteFormat.string($0.originalBytes) } ?? "—"
            return RowDescriptor(meta: meta, emphasis: .none,
                                 trailing: .sizeColumn(current: sizeText, target: sizeText,
                                                        kind: .unchanged, sameSize: true),
                                 canOpen: true, capsuleTitle: capsuleTitle(row))
        }
        let isSearchable = row?.searchableByCard[.shipped] == true
        let meta: String
        if sizes.after > sizes.before {
            // Spec §6.3's specified divergence: the design has no "grew" state.
            meta = "Searchable now · grew slightly"
        } else {
            let percent = percentSmaller(before: sizes.before, after: sizes.after)
            if isSearchable {
                // The STORE's shipped variant, never `outcome.shippedVariant`:
                // a change-quality re-run overwrites the store's card but leaves `outcome` as the
                // FIRST run left it, so a Balanced-MRC row re-run at Maximum quality (a plain gs
                // file) would otherwise still read "Rebuilt".
                let verb = row?.shipped?.variant == .mrc ? "Rebuilt" : "Compressed"
                meta = "\(verb) and searchable · \(percent)"
            } else if state == .working, let duration = model.rowDuration(for: job.id) {
                meta = "\(percent) · finished in \(Int(duration.rounded())) second\(Int(duration.rounded()) == 1 ? "" : "s")"
            } else {
                // The STORE's shipped file first: it is the authoritative
                // delivered path, ahead of the reservation ledger or the queue's own `resultURL`.
                let name = row?.shipped?.url.lastPathComponent
                    ?? model.reservedDelivery(for: job.id)?.lastPathComponent
                    ?? job.resultURL?.lastPathComponent ?? job.url.lastPathComponent
                meta = "\(percent) · saved as \(name)"
            }
        }
        return RowDescriptor(
            meta: meta, emphasis: .none,
            trailing: .sizeColumn(current: QueueByteFormat.string(sizes.before),
                                  target: QueueByteFormat.string(sizes.after),
                                  kind: .finished),
            canOpen: true, capsuleTitle: capsuleTitle(row)
        )
    }

    /// Rescued/tooFaint/cancelled-between-legs/read-failure-after-delivery rows (spec §6.5/§7):
    /// delivered, but with an honest caveat — `.degraded` emphasis (no tint), `StatusIndicator
    /// .warn`. Copy per the plan's recorded divergences where one is pinned; composed, with an
    /// owner note, where none exists.
    private static func describeDegraded(job: ToolJob, model: QueueViewModel, outcome: RowOutcome) -> RowDescriptor {
        let sizes = model.displayedSizes(for: job)
        let meta: String
        if case .skipped = outcome.compress {
            // The compress-failure OCR rescue.
            switch outcome.ocr {
            case .added: meta = "Couldn't be compressed — made searchable instead"
            default: meta = "Couldn't be compressed"   // .alreadySearchable/.tooFaint: rescue leg shipped nothing
            }
        } else if case .noGain = outcome.compress {
            // No compression needed, but OCR leg produced a degraded outcome (spec §6.5, DESIGN.md §11).
            // The spec pins "Already optimised · too faint to read" for `.tooFaint`, the only OCR
            // outcome a noGain row's `.done` state can actually carry: `.added`/`.alreadySearchable`
            // aren't degraded at all (`RowOutcome.isDegraded`), and `.cancelled`/`.failed` can't reach
            // a noGain row here either — its OCR leg always runs with `delivers: true` (a noGain
            // compress leg never sets `state.delivered`), so a cancellation or read failure aborts the
            // whole job to `.failed` (`ocrLeg`'s `guard delivers else { return nil }`) before a `.done`
            // outcome can exist. `default` is defensive only, never a live state.
            switch outcome.ocr {
            case .tooFaint:
                meta = "Already optimised · too faint to read"
            default:
                meta = "Already optimised"
            }
        } else if outcome.ocr == .cancelled {
            meta = "Compressed · not searchable — cancelled before reading"
        } else if outcome.ocr == .tooFaint {
            // Distinguish: compress-carrying rows say "compressed", OCR-only rows (compress nil)
            // are honest about having never been compressed (spec §6.5).
            if outcome.compress != nil {
                meta = "Too faint to read — compressed, but not searchable"
            } else {
                meta = "Too faint to read — not searchable"
            }
        } else if case .failed(let reason) = outcome.ocr {
            // No handoff/spec string for a read that fails AFTER a successful compress delivery
            // (recorded divergence): names the compress fact plus the OCR failure reason.
            meta = "Compressed, but not searchable — \(reason)"
        } else {
            meta = "Compressed, but not searchable"
        }
        // `displayedSizes` is nil for the whole rescue family (compress `.skipped` never gets a
        // `VersionStore` row) — never stale to read `outcome.finalBytes` directly
        // there, because a row with no store entry can never re-arm and so never disagrees with
        // this figure later (the one documented exception to the model-vs-outcome staleness rule above).
        let sizeText = sizes.map { QueueByteFormat.string($0.after) } ?? QueueByteFormat.string(outcome.finalBytes)
        return RowDescriptor(meta: meta, emphasis: .degraded,
                             trailing: .status(text: sizeText, kind: .warn),
                             canOpen: true, capsuleTitle: capsuleTitle(model.versions(for: job)))
    }

    private static func percentSmaller(before: Int, after: Int) -> String {
        guard before > 0 else { return "0% smaller" }
        let percent = Int(((Double(before - after) / Double(before)) * 100).rounded())
        return "\(percent)% smaller"
    }

    /// The versions capsule renders only when a parked version exists (component doc comment).
    private static func capsuleTitle(_ row: RowVersions?) -> String? {
        guard let row, row.runnerUp != nil || row.previous != nil else { return nil }
        return row.capsuleTitle
    }

    // MARK: failed (run-time terminal failure)

    /// A row whose job ended `.failed` — `CompressLegFailure`/`OpenGuard`'s run-time catch/
    /// encrypted/corrupt. `OpenGuard`'s run-time inspection is the "second net" (spec §6.6): a
    /// file that moved, locked, or became unreadable between add and run raises the exact same
    /// condition inspection would have caught, so it renders through `describeProblem` — same
    /// copy, same tint, same affordances (including "Find it…" on a moved row) as the add-time
    /// path, never the raw engine string. A genuine run-time-only failure (Ghostscript,
    /// validation) has no add-time equivalent: the Global Constraints pin Skip/Remove for exactly
    /// that family ("Couldn't be compressed" + Skip/Remove), and its message stays as-is.
    private static func describeFailed(job: ToolJob, model: QueueViewModel, message: String) -> RowDescriptor {
        if let problem = RowProblem.fromRunTimeFailure(message) {
            return describeProblem(job: job, model: model, problem: problem, meta: problem.problemCopy)
        }
        // Skip/Remove/Undo all refuse mid-run (`setSkipped`/`remove`'s own `!isRunning` guards) —
        // absent for the run's duration rather than a silently-refused no-op button.
        if model.skippedRows.contains(job.id) {
            let undo = model.isRunning ? nil :
                RowDescriptor.RowAction(title: "Undo", action: { model.setSkipped(false, for: job.id) })
            return RowDescriptor(meta: message, emphasis: .degraded, trailing: .skipped(onUndo: undo))
        }
        let skip = model.isRunning ? nil :
            RowDescriptor.RowAction(title: "Skip", action: { model.setSkipped(true, for: job.id) })
        let remove = model.isRunning ? nil :
            RowDescriptor.RowAction(title: "Remove", action: { model.remove(job) })
        return RowDescriptor(meta: message, emphasis: .problemDanger, trailing: .problemPair(skip, remove))
    }
}

#Preview("Rows – mixed") {
    QueueRowsView(model: QueueViewModel(), state: .ready)
        .frame(width: 900, height: 400)
        .background(Theme.Colors.surface)
}
