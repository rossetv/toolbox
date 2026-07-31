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
/// from the model (binding carry #1: `displayedSizes`/`searchableByCard[.shipped]`, never
/// `job.state`'s `RowOutcome` alone — the outcome is stale after a re-run and disagrees by design
/// on the all-lossy path).
struct QueueRowsView: View {
    @ObservedObject var model: QueueViewModel
    let state: QueueScreenState
    let perFile: (ToolJob.ID) -> AnyView
    let versions: (ToolJob.ID) -> AnyView

    @State private var perFileJobID: ToolJob.ID?
    @State private var versionsJobID: ToolJob.ID?

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.jobs) { job in
                    row(for: job)
                }
                if state == .ready {
                    dropHint
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
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
            perFile(job.id)
        }
        .popover(isPresented: Binding(get: { versionsJobID == job.id }, set: { if !$0 { versionsJobID = nil } })) {
            versions(job.id)
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
        case .sizeColumn(let current, let target, let targetColor):
            return AnyView(QueueRowSizeColumn(current: current, target: target,
                                              targetColor: targetColor ?? Theme.Colors.textSecondary))
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
                LinkButton(title: link.title, action: link.action)
            })
        case .problemPair(let first, let second):
            return AnyView(HStack(spacing: 10) {
                LinkButton(title: first.title, action: first.action)
                LinkButton(title: second.title, action: second.action)
            })
        case .skipped(let onUndo):
            return AnyView(HStack(spacing: 10) {
                Text("Skipped").themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
                LinkButton(title: onUndo.title, action: onUndo.action)
            })
        }
    }

    // MARK: pure, testable derivation

    /// One row's presentation, entirely determined by the model — the piece `QueueViewStateTests`
    /// exercises directly (a SwiftUI body cannot be unit-tested; this can).
    struct RowDescriptor: Equatable {
        enum Trailing: Equatable {
            case sizeColumn(current: String, target: String, targetColor: Color?)
            case status(text: String?, kind: StatusIndicator.Kind)
            case problem(primary: RowAction?, link: RowAction)
            case problemPair(RowAction, RowAction)
            case skipped(onUndo: RowAction)

            static func == (lhs: Trailing, rhs: Trailing) -> Bool {
                switch (lhs, rhs) {
                case (.sizeColumn(let a, let b, let c), .sizeColumn(let d, let e, let f)):
                    return a == d && b == e && c == f
                case (.status(let a, let b), .status(let c, let d)):
                    return a == c && b == d
                case (.problem(let a, let b), .problem(let c, let d)):
                    return a?.title == c?.title && b.title == d.title
                case (.problemPair(let a, let b), .problemPair(let c, let d)):
                    return a.title == c.title && b.title == d.title
                case (.skipped(let a), .skipped(let b)):
                    return a.title == b.title
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
        var metaAccent: String? = nil
        var emphasis: QueueRow<AnyView>.Emphasis = .none
        var trailing: Trailing
        var canOpen = false
        var canConfigure = false
        var canRemove = false
        var capsuleTitle: String? = nil

        static func == (lhs: RowDescriptor, rhs: RowDescriptor) -> Bool {
            lhs.meta == rhs.meta && lhs.metaAccent == rhs.metaAccent
                && emphasisEqual(lhs.emphasis, rhs.emphasis)
                && lhs.trailing == rhs.trailing && lhs.canOpen == rhs.canOpen
                && lhs.canConfigure == rhs.canConfigure && lhs.canRemove == rhs.canRemove
                && lhs.capsuleTitle == rhs.capsuleTitle
        }

        /// `QueueRow.Emphasis` (F7, `QueueComponents.swift`) has no associated values but was
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
    /// size or a searchability word (binding carry #1).
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
        guard let estimate = job.estimate, let inputBytes = QueueByteFormat.size(of: job.url) else {
            return RowDescriptor(meta: meta, trailing: .sizeColumn(current: "—", target: "—", targetColor: nil),
                                  canOpen: true, canConfigure: true, canRemove: true)
        }
        let marker = estimate.isFallback ? "~" : "\u{2248}"
        return RowDescriptor(
            meta: meta,
            trailing: .sizeColumn(current: QueueByteFormat.string(inputBytes),
                                  target: "\(marker)\(QueueByteFormat.string(estimate.predictedBytes))",
                                  targetColor: nil),
            canOpen: true, canConfigure: true, canRemove: true
        )
    }

    /// Locked/moved/unreadable rows (spec §6.6/§7). Password unlock is deferred (D3, non-goal §3):
    /// the locked row gets Skip/Remove only, never an "Enter password…" affordance. "Unreadable"
    /// gets the same Skip/Remove treatment as locked (recorded divergence, P-A) — it names a file
    /// that IS present but is not a usable PDF, which "Find it…" (a re-pick for a file that has
    /// MOVED) does not describe; "Moved or renamed" is the one case with an in-app fix, so it
    /// alone gets `.problemWarn` + "Find it…".
    private static func describeProblem(job: ToolJob, model: QueueViewModel,
                                        problem: RowProblem, meta: String) -> RowDescriptor {
        let skip = RowDescriptor.RowAction(title: "Skip", action: { model.setSkipped(true, for: job.id) })
        let remove = RowDescriptor.RowAction(title: "Remove", action: { model.remove(job) })
        if model.skippedRows.contains(job.id) {
            let undo = RowDescriptor.RowAction(title: "Undo", action: { model.setSkipped(false, for: job.id) })
            return RowDescriptor(meta: meta, emphasis: .degraded, trailing: .skipped(onUndo: undo))
        }
        switch problem {
        case .missing:
            let findIt = RowDescriptor.RowAction(title: "Find it…", action: { rebindViaOpenPanel(job, model: model) })
            return RowDescriptor(meta: meta, emphasis: .problemWarn, trailing: .problem(primary: findIt, link: remove))
        case .locked, .unreadable:
            return RowDescriptor(meta: meta, emphasis: .problemDanger, trailing: .problemPair(skip, remove))
        case .compressFailed:
            // Unreachable from add-time inspection (F4's own note) — never produced here.
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
        return RowDescriptor(meta: leg, metaAccent: nil, emphasis: .none,
                             trailing: .status(text: etaText, kind: .active(fraction)))
    }

    // MARK: done

    private static func describeDone(job: ToolJob, model: QueueViewModel, state: QueueScreenState) -> RowDescriptor {
        guard case .done(let outcome) = job.state else { fatalError("describeDone requires a .done job") }
        if outcome.isDegraded {
            return describeDegraded(job: job, model: model, outcome: outcome)
        }
        let row = model.versions(for: job)
        guard let sizes = model.displayedSizes(for: job) else {
            // No shipped version: a compress-only no-gain row (truly nothing changed), or the
            // noGain+OCR-added sibling (`row` recorded, `shipped` nil — spec §6.5's grey sizes).
            let isSearchable = row?.searchableByCard[.shipped] == true
            let meta = isSearchable ? "Already optimised · made searchable" : "Already optimised"
            let sizeText = row.map { QueueByteFormat.string($0.originalBytes) }
            return RowDescriptor(meta: meta, emphasis: .none, trailing: .status(text: sizeText, kind: .unchanged),
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
                let verb = outcome.shippedVariant == .mrc ? "Rebuilt" : "Compressed"
                meta = "\(verb) and searchable · \(percent)"
            } else if state == .working, let duration = model.rowDuration(for: job.id) {
                meta = "\(percent) · finished in \(Int(duration.rounded())) second\(Int(duration.rounded()) == 1 ? "" : "s")"
            } else {
                // The STORE's shipped file first (binding carry #1): it is the authoritative
                // delivered path, ahead of the reservation ledger or the queue's own `resultURL`.
                let name = row?.shipped?.url.lastPathComponent
                    ?? model.reservedDelivery(for: job.id)?.lastPathComponent
                    ?? job.resultURL?.lastPathComponent ?? job.url.lastPathComponent
                meta = "\(percent) · saved as \(name)"
            }
        }
        return RowDescriptor(
            meta: meta, emphasis: .none,
            trailing: .status(text: QueueByteFormat.string(sizes.after), kind: .finished),
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
            // The compress-failure OCR rescue (F5a-owned copy; P-A renders).
            switch outcome.ocr {
            case .added: meta = "Couldn't be compressed — made searchable instead"
            default: meta = "Couldn't be compressed"   // .alreadySearchable/.tooFaint: rescue leg shipped nothing
            }
        } else if outcome.ocr == .cancelled {
            meta = "Compressed · not searchable — cancelled before reading"
        } else if outcome.ocr == .tooFaint {
            meta = "Too faint to read — compressed, but not searchable"
        } else if case .failed(let reason) = outcome.ocr {
            // No handoff/spec string for a read that fails AFTER a successful compress delivery
            // (recorded divergence, P-A): names the compress fact plus the OCR failure reason.
            meta = "Compressed, but not searchable — \(reason)"
        } else {
            meta = "Compressed, but not searchable"
        }
        // `displayedSizes` is nil for the whole rescue family (compress `.skipped` never gets a
        // `VersionStore` row — F6's note) — never stale to read `outcome.finalBytes` directly
        // there, because a row with no store entry can never re-arm and so never disagrees with
        // this figure later (the one documented exception to binding carry #1's staleness rule).
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
    /// encrypted/corrupt. The message is already the model's own user-facing string (never
    /// recomposed here); the Global Constraints pin Skip/Remove for exactly this family
    /// ("Couldn't be compressed" + Skip/Remove) — "Find it…" names a FIX ("Moved" is the one
    /// add-time problem with one), which a terminal run failure does not have short of a rebind.
    private static func describeFailed(job: ToolJob, model: QueueViewModel, message: String) -> RowDescriptor {
        if model.skippedRows.contains(job.id) {
            let undo = RowDescriptor.RowAction(title: "Undo", action: { model.setSkipped(false, for: job.id) })
            return RowDescriptor(meta: message, emphasis: .degraded, trailing: .skipped(onUndo: undo))
        }
        let skip = RowDescriptor.RowAction(title: "Skip", action: { model.setSkipped(true, for: job.id) })
        let remove = RowDescriptor.RowAction(title: "Remove", action: { model.remove(job) })
        return RowDescriptor(meta: message, emphasis: .problemDanger, trailing: .problemPair(skip, remove))
    }
}

#Preview("Rows – mixed") {
    QueueRowsView(model: QueueViewModel(), state: .ready,
                  perFile: { _ in AnyView(EmptyView()) }, versions: { _ in AnyView(EmptyView()) })
        .frame(width: 900, height: 400)
        .background(Theme.Colors.surface)
}
