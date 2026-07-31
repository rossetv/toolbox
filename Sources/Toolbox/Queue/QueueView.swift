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
/// presenting the eight sibling-track popovers/sheets this type does not itself compose.
///
/// The nine-slot seam below is FROZEN (spec P-A task): I1 plugs P-B's views into exactly these
/// slots and no other cross-track reference exists. `showAbout` is the one shared presentation
/// state — `QueueView` presents the About sheet off it, the `⋯` menu's "About Toolbox" item and
/// `ToolboxApp`'s app-menu command both toggle the SAME binding.
struct QueueView: View {
    @ObservedObject var model: QueueViewModel
    @ObservedObject var history: HistoryStore

    let quality: () -> AnyView
    let ocrOptions: () -> AnyView
    let perFile: (ToolJob.ID) -> AnyView
    let versions: (ToolJob.ID) -> AnyView
    let changeQuality: () -> AnyView
    let scanConsent: (ToolJob.ID) -> AnyView
    let recentBatches: () -> AnyView
    let about: () -> AnyView
    let showAbout: Binding<Bool>

    init(model: QueueViewModel, history: HistoryStore,
         quality: @escaping () -> AnyView,
         ocrOptions: @escaping () -> AnyView,
         perFile: @escaping (ToolJob.ID) -> AnyView,
         versions: @escaping (ToolJob.ID) -> AnyView,
         changeQuality: @escaping () -> AnyView,
         scanConsent: @escaping (ToolJob.ID) -> AnyView,
         recentBatches: @escaping () -> AnyView,
         about: @escaping () -> AnyView,
         showAbout: Binding<Bool>) {
        self.model = model
        self.history = history
        self.quality = quality
        self.ocrOptions = ocrOptions
        self.perFile = perFile
        self.versions = versions
        self.changeQuality = changeQuality
        self.scanConsent = scanConsent
        self.recentBatches = recentBatches
        self.about = about
        self.showAbout = showAbout
    }

    @State private var isTargeted = false
    @State private var draggedCount = 1
    @State private var changeQualityPresented = false
    @State private var recentBatchesPresented = false

    /// nil exactly when nothing is waiting — surfaces the FIFO's head, one at a time (spec §7).
    private var consentJobID: ToolJob.ID? { model.pendingConsents.first }

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
                    quality: quality, ocrOptions: ocrOptions,
                    onAdd: { model.add(FilePicker.choosePDFs()) },
                    onClear: { model.clearFinished() },
                    onChooseFolder: { if let folder = FilePicker.chooseFolder() { model.outputFolder = folder } },
                    onRecentBatches: { recentBatchesPresented = true },
                    onAbout: { showAbout.wrappedValue = true },
                    onCancel: { model.cancel() }
                )
                Divider()
                QueueRowsView(model: model, state: screenState, perFile: perFile, versions: versions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                QueueFooterView(
                    model: model, state: screenState,
                    onStart: { model.compress() },
                    onCancel: { model.cancel() },
                    onShowInFinder: { revealShipped() },
                    onChangeQuality: { changeQualityPresented = true },
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
        .sheet(isPresented: $changeQualityPresented) { changeQuality() }
        .sheet(isPresented: $recentBatchesPresented) { recentBatches() }
        .sheet(isPresented: showAbout) { about() }
        .sheet(isPresented: Binding(get: { consentJobID != nil }, set: { _ in })) {
            if let consentJobID { scanConsent(consentJobID) }
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
    return QueueView(
        model: model, history: model.history,
        quality: { AnyView(EmptyView()) }, ocrOptions: { AnyView(EmptyView()) },
        perFile: { _ in AnyView(EmptyView()) }, versions: { _ in AnyView(EmptyView()) },
        changeQuality: { AnyView(EmptyView()) }, scanConsent: { _ in AnyView(EmptyView()) },
        recentBatches: { AnyView(EmptyView()) }, about: { AnyView(EmptyView()) },
        showAbout: .constant(false)
    )
    .frame(width: 900, height: 640)
}
