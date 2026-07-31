// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which of the design's screens the window is currently showing (handoff README §Screens).
/// Derived, never stored: re-deriving on every read is what keeps this from disagreeing with the
/// model it is computed from.
enum QueueScreenState: Equatable {
    /// Screen 01 — nothing queued yet.
    case empty
    /// Screen 03 — queued (and possibly problem) rows, nothing has run yet.
    case ready
    /// Screen 05 — a batch is in flight (D2: any number of rows may be active at once).
    case working
    /// Screen 06 — every row finished cleanly (no failures, no lingering unresolved problem).
    case finished
    /// Screen 10 — at least one row failed, or a problem row from add-time inspection was never
    /// resolved before the rest of the batch completed.
    case problems
}

/// The main window's single content view (handoff: "the window is one thing"). Hosts every
/// screen the design specifies as one state machine over `QueueViewModel` + `HistoryStore`,
/// and constructs every popover/sheet it presents directly — `QualityPopover`, `OCRPopover`,
/// `PerFileSettingsPopover`, `VersionsPopoverContent`, `ChangeQualitySheet`, `ScanConsentSheet`,
/// `RecentBatchesSheet`, `AboutView` — since all of them live in this module. `showAbout` is the
/// one genuinely externally-owned piece of state — `QueueView` presents the About sheet off it,
/// the `⋯` menu's "About Toolbox" item and `ToolboxApp`'s app-menu command both toggle the SAME
/// binding.
struct QueueView: View {
    @ObservedObject var model: QueueViewModel
    @ObservedObject var history: HistoryStore
    let showAbout: Binding<Bool>

    init(model: QueueViewModel, history: HistoryStore, showAbout: Binding<Bool>) {
        self.model = model
        self.history = history
        self.showAbout = showAbout
    }

    @State private var isTargeted = false
    @State private var draggedCount = 1
    @State private var activeSheet: QueueSheet?
    /// Owned here, not by `QueueHeaderView`, so `QueueRowsView` — a sibling — can dim off the
    /// same state (spec §7, DESIGN.md §9 04/04b: "the queue behind dims to 40% while open").
    @State private var qualityPresented = false
    @State private var ocrPresented = false

    var screenState: QueueScreenState {
        Self.screenState(jobs: model.jobs, isRunning: model.isRunning, inspections: model.inspections)
    }

    var body: some View {
        VStack(spacing: 0) {
            if screenState == .empty {
                EmptyStateView(history: history) {
                    model.add(FilePicker.choosePDFs())
                }
            } else {
                QueueHeaderView(
                    model: model, state: screenState,
                    quality: { AnyView(QualityPopover(model: model)) },
                    ocrOptions: { AnyView(OCRPopover(model: model)) },
                    onAdd: { model.add(FilePicker.choosePDFs()) },
                    onClear: { model.clearFinished() },
                    onChooseFolder: { if let folder = FilePicker.chooseFolder() { model.outputFolder = folder } },
                    onRecentBatches: { activeSheet = .recentBatches },
                    onAbout: { showAbout.wrappedValue = true },
                    onCancel: { model.cancel() },
                    qualityPresented: $qualityPresented, ocrPresented: $ocrPresented
                )
                Divider()
                QueueRowsView(
                    model: model, state: screenState,
                    perFile: { AnyView(PerFileSettingsPopover(model: model, jobID: $0)) },
                    versions: { AnyView(VersionsPopoverContent(model: model, jobID: $0)) }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(Self.rowsDimOpacity(qualityOpen: qualityPresented, ocrOpen: ocrPresented))
                Divider()
                QueueFooterView(
                    model: model, state: screenState,
                    onStart: { model.compress() },
                    onCancel: { model.cancel() },
                    onShowInFinder: { revealShipped() },
                    onChangeQuality: { activeSheet = .changeQuality },
                    onAddMore: { model.add(FilePicker.choosePDFs()) }
                )
            }
        }
        .background(Theme.Colors.surface)
        .overlay {
            if isTargeted { DragOverlayView(fileCount: draggedCount) }
        }
        .onDrop(of: [.fileURL], delegate: QueueDropDelegate(
            isTargeted: $isTargeted, draggedCount: $draggedCount,
            onDrop: { acceptDrop($0) }
        ))
        // A single `.sheet(item:)` over one optional enum — NOT four stacked `.sheet(isPresented:)`
        // modifiers on the same view, which is a known SwiftUI failure mode (later modifiers can
        // shadow earlier ones so only one ever actually presents). Keying on `QueueSheet.id` also
        // fixes the consent FIFO: a derived `isPresented` Bool (`consentJobID != nil`) never goes
        // false between two queued consents, so SwiftUI has no edge to dismiss-then-represent on —
        // the second row's sheet would never appear. An `Identifiable` item forces a clean
        // dismiss+present on every id change, including consent → consent (spec §7's multi-scan case).
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .changeQuality: ChangeQualitySheet(model: model)
            case .recentBatches: RecentBatchesSheet(history: history)
            case .about: AboutView()
            case .consent(let id): ScanConsentSheet(model: model, jobID: id)
            }
        }
        // Drives the FIFO: any change to the queue's head re-targets `activeSheet`. If the head
        // becomes nil while a consent sheet is up (the user resolved it through P-B's own content,
        // which pops the queue), clear it too. A user who dismisses the sheet directly (Escape) —
        // rather than resolving it — leaves that row's consent unresolved with no forced re-prompt;
        // the versions capsule remains the undo path per spec §7, so this is accepted, not a gap.
        .onChange(of: model.pendingConsents.first) { _, newHead in
            if let newHead {
                activeSheet = .consent(newHead)
            } else if case .consent = activeSheet {
                activeSheet = nil
            }
        }
        // Bridges the externally-owned `showAbout` binding (shared with `ToolboxApp`'s app-menu
        // command) onto the single sheet surface, both directions. Each branch only writes when the
        // value would actually change, so the two handlers below settle in one hop and never ping-pong.
        .onChange(of: showAbout.wrappedValue) { _, isShowing in
            if isShowing {
                activeSheet = .about
            } else if case .about = activeSheet {
                activeSheet = nil
            }
        }
        .onChange(of: activeSheet) { _, newValue in
            if case .about = newValue {
                if !showAbout.wrappedValue { showAbout.wrappedValue = true }
            } else if showAbout.wrappedValue {
                showAbout.wrappedValue = false
            }
        }
    }

    /// Reveals every row's delivered file, falling back to the originals when nothing shipped
    /// (every row was already optimised) — mirrors the pre-redesign `CompressView`'s own fallback.
    private func revealShipped() {
        let outputs = model.jobs.compactMap { model.versions(for: $0)?.shipped?.url ?? $0.resultURL }
        let urls = outputs.isEmpty ? model.jobs.map(\.url) : outputs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Drop is accepted in EVERY screen state, including mid-run (spec §6.5) — a thin, directly
    /// testable seam: `.onDrop`'s closures cannot be invoked from a unit test, but a plain method
    /// can. `model.add` itself carries no state guard, so this never gates on `screenState`.
    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        model.add(urls)
        return true
    }

    /// Pure state-selection (`QueueViewStateTests`): empty until the first file lands; ready until
    /// anything has reached a terminal state; working while a batch runs; otherwise finished when
    /// every terminal row succeeded cleanly, problems when at least one failed or a still-queued
    /// row carries an unresolved add-time problem (a locked/missing/unreadable file the user has
    /// neither fixed nor skipped past — left behind once the rest of the batch has finished).
    ///
    /// `allFinished` is NOT this function: a skipped problem row stays `.queued` forever (it is
    /// never included in a run), which would make `allFinished` permanently false in exactly the
    /// state screen 10 depicts — so this is derived independently, from the jobs themselves.
    static func screenState(jobs: [ToolJob], isRunning: Bool,
                            inspections: [ToolJob.ID: RowInspection]) -> QueueScreenState {
        guard !jobs.isEmpty else { return .empty }
        if isRunning { return .working }
        var hasFailed = false
        var hasTerminal = false
        var hasUnresolvedProblem = false
        for job in jobs {
            switch job.state {
            case .done:
                hasTerminal = true
            case .failed:
                hasTerminal = true
                hasFailed = true
            case .queued, .analysing:
                if inspections[job.id]?.problem != nil { hasUnresolvedProblem = true }
            case .running:
                break   // unreachable once `isRunning` is false, kept for exhaustiveness
            }
        }
        guard hasTerminal else { return .ready }
        return (hasFailed || hasUnresolvedProblem) ? .problems : .finished
    }

    /// The rows area's opacity while the Quality or OCR popover is open (spec §7, DESIGN.md §9
    /// 04/04b — "the queue behind dims to 40% while open"; the handoff HTML dims the rows list
    /// alone, identically for both popovers, never the header/footer/separators). No animation
    /// is applied at the call site, so this is unanimated under Reduce Motion and otherwise
    /// alike — the handoff's own rows dim carries no transition either.
    static func rowsDimOpacity(qualityOpen: Bool, ocrOpen: Bool) -> Double {
        (qualityOpen || ocrOpen) ? 0.4 : 1.0
    }
}

/// The single presentation surface for every sheet `QueueView` owns — see the doc comment on the
/// `.sheet(item:)` call site for why this replaces four separately-toggled `.sheet(isPresented:)`
/// modifiers.
private enum QueueSheet: Identifiable, Equatable {
    case changeQuality
    case recentBatches
    case about
    case consent(ToolJob.ID)

    var id: String {
        switch self {
        case .changeQuality: return "changeQuality"
        case .recentBatches: return "recentBatches"
        case .about: return "about"
        case .consent(let jobID): return "consent-\(jobID)"
        }
    }
}

/// Backs the drag-over screen (02): tracks whether the pointer holds files over the window and,
/// unlike the simple `.onDrop(of:isTargeted:perform:)` closure form, how many — `DropInfo` only
/// exposes the dragged item count while hovering, through `itemProviders(for:)`, which the
/// closure form never surfaces at all.
private struct QueueDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var draggedCount: Int
    let onDrop: ([URL]) -> Void

    func dropEntered(info: DropInfo) {
        isTargeted = true
        draggedCount = max(1, info.itemProviders(for: [.fileURL]).count)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        draggedCount = max(1, info.itemProviders(for: [.fileURL]).count)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in onDrop([url]) }
            }
        }
        return true
    }
}

#Preview("Queue – Ready") {
    let model = QueueViewModel()
    return QueueView(model: model, history: model.history, showAbout: .constant(false))
        .frame(width: 900, height: 640)
}
