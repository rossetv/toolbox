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
/// screen the design specifies as one state machine over `QueueViewModel` + `HistoryStore`, and
/// constructs the sheets it presents directly — `ChangeQualitySheet`, `ScanConsentSheet`,
/// `RecentBatchesSheet`, `AboutView` — since all of them live in this module. `QualityPopover`,
/// `OCRPopover`, `PerFileSettingsPopover`, `VersionsPopoverContent` are constructed by
/// `QueueHeaderView`/`QueueRowsView` themselves, each with exactly one caller. `showAbout` is the
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var draggedCount = 1
    @State private var activeSheet: QueueSheet?
    /// Owned here, not by `QueueHeaderView`, so `QueueRowsView` — a sibling — can dim off the
    /// same state (spec §7, DESIGN.md §9 04/04b: "the queue behind dims to 40% while open").
    @State private var qualityPresented = false
    @State private var ocrPresented = false

    var screenState: QueueScreenState {
        Self.screenState(jobs: model.jobs, isRunning: model.isRunning, inspections: model.inspections,
                         skipped: model.skippedRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            if screenState == .empty {
                // The empty state's own centred stack sits exactly where the drag-over screen puts
                // its fan and headline, so both were legible through each other while a drag was
                // over the window. It steps aside for the duration (DESIGN.md §9 02).
                EmptyStateView(history: history, isDropTargeted: isTargeted) {
                    model.add(FilePicker.choosePDFs())
                }
                // The window becoming (or ceasing to be) a queue is the biggest change it makes:
                // the two sides cross-fade and settle a few points rather than cutting.
                .transition(.opacity.combined(with: .offset(y: 10)))
            } else {
                queueScreen
                    .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        // Scopes one spring to everything the screen change touches — the empty↔queue swap above,
        // and the header/footer swapping their own copy and controls underneath. Deliberately NOT
        // `.id(screenState)`: that would give the same cross-fade by tearing the subtree down and
        // rebuilding it, throwing away every `@State` behind it — each row's rendered thumbnail,
        // the chrome views' entrance flags, the sweep offsets — and re-parsing every PDF on the
        // way from ready to working.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: screenState)
        .background(Theme.Colors.surface)
        .overlay {
            if isTargeted { DragOverlayView(fileCount: draggedCount) }
        }
        .onDrop(of: [.fileURL], delegate: QueueDropDelegate(
            isTargeted: $isTargeted, draggedCount: $draggedCount,
            onDrop: { acceptDrop($0) }
        ))
        // An IN-WINDOW overlay, not `.sheet(...)`: `SheetChrome` draws the whole modal itself — its
        // own dim, its own card, 52pt below the titlebar (DESIGN.md §9 11) — so a system sheet
        // wrapped that card in a second window-shaped container, which is what read as a stray
        // frame around About/Recent batches/Change quality. Presenting here also puts every sheet
        // control back inside the main window, so `WindowSetup`'s stray-focus-ring net covers them.
        //
        // One optional enum drives it — NOT four booleans, which is a known SwiftUI failure mode
        // when stacked as `.sheet(isPresented:)` modifiers. `.id(sheet.id)` is load-bearing and
        // carries over from the `.sheet(item:)` this replaces: it forces a clean teardown+rebuild
        // on every id change, including consent → consent (spec §7's multi-scan case), which a
        // bare `if let` would not — SwiftUI would reuse the view and its `@State` across two
        // different rows' consents.
        .overlay {
            if let sheet = activeSheet {
                sheetContent(sheet)
                    .id(sheet.id)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: activeSheet)
        // Drives the FIFO: any change to the queue's head re-targets `activeSheet`. If the head
        // becomes nil while a consent sheet is up (the user resolved it through the sheet's own
        // content, which pops the queue), clear it too. A user who dismisses the sheet directly (Escape) —
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

    /// One presented sheet, plus the Escape path a system sheet used to give for free — including
    /// the consent sheet, which spec §7 explicitly allows to be escaped without resolving.
    @ViewBuilder
    private func sheetContent(_ sheet: QueueSheet) -> some View {
        let close = { activeSheet = nil }
        Group {
            switch sheet {
            case .changeQuality: ChangeQualitySheet(model: model, onClose: close)
            case .recentBatches: RecentBatchesSheet(history: history, onClose: close)
            case .about: AboutView(onClose: close)
            case .consent(let id): ScanConsentSheet(model: model, jobID: id)
            }
        }
        .escapeToDismiss(close)
    }

    /// Screens 03/05/06/10 — header, rows, footer. One property rather than an inline `else`
    /// branch so the branch can carry a transition without burying it in the body.
    private var queueScreen: some View {
        Group {
            QueueHeaderView(
                model: model, state: screenState,
                onAdd: { model.add(FilePicker.choosePDFs()) },
                onClear: { model.clearFinished() },
                onChooseFolder: { if let folder = FilePicker.chooseFolder() { model.outputFolder = folder } },
                onRecentBatches: { activeSheet = .recentBatches },
                onAbout: { showAbout.wrappedValue = true },
                onCancel: { model.cancel() },
                qualityPresented: $qualityPresented, ocrPresented: $ocrPresented
            )
            Divider()
            QueueRowsView(model: model, state: screenState)
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
    ///
    /// The one deliberate exception to "drop works everywhere": while `FilePicker`'s Choose
    /// Files/Choose Folder panel is up. That panel is a synchronous, blocking `NSOpenPanel.runModal()`
    /// call (`FilePicker.swift`) — a drop accepted underneath it mutates the queue while the modal
    /// session is still live and left the panel (and any consent sheet it triggers) unable to
    /// dismiss, Escape/Cancel dead, reproduced live. `NSApp.modalWindow` is non-nil for exactly the
    /// duration of that `runModal()` call, so it's read as the default here — overridable so the
    /// gate itself (`shouldAcceptDrop`) is testable without a real panel on screen.
    @discardableResult
    func acceptDrop(_ urls: [URL], modalWindowPresented: Bool = NSApp.modalWindow != nil) -> Bool {
        guard Self.shouldAcceptDrop(modalWindowPresented: modalWindowPresented) else { return false }
        model.add(urls)
        return true
    }

    /// Pure gate backing `acceptDrop`: refuse while a modal panel (`FilePicker`) is presented, since
    /// it — not the drop target underneath — is the active affordance.
    static func shouldAcceptDrop(modalWindowPresented: Bool) -> Bool {
        !modalWindowPresented
    }

    /// Pure state-selection (`QueueViewStateTests`): empty until the first file lands; ready until
    /// anything has reached a terminal state; working while a batch runs; otherwise finished when
    /// every terminal row succeeded cleanly, problems when at least one failed row or unresolved
    /// problem row (a locked/missing/unreadable file, or a run-time failure, the user has neither
    /// fixed nor skipped past) is left behind once the rest of the batch has finished. Every row
    /// is classified once via `QueueRowPartition.classify` — the one shared predicate
    /// `QueueViewModel.healthyQueuedCount` and `QueueHeaderView.problemsSubtitle`/
    /// `problemsHeadline` also derive from, so a skip resolves a row identically everywhere. A
    /// skipped failed row or skipped problem row is resolved-by-skip and excluded from both
    /// `hasFailed` and `hasUnresolvedProblem`.
    ///
    /// `allFinished` is NOT this function: a skipped problem row stays `.queued` forever (it is
    /// never included in a run), which would make `allFinished` permanently false in exactly the
    /// state screen 10 depicts — so this is derived independently, from the jobs themselves.
    ///
    /// Add More on a finished OR problems batch (spec §7) appends a clean `.queued` row — no
    /// problem, not skipped — alongside the batch's terminal rows. That row is real, runnable
    /// work the idle queue is sitting on, so it must pull the screen back to `.ready` (mixed
    /// done+pending, or failed/skipped+pending, rows on screen 03) rather than leaving it on
    /// `.finished`/`.problems`, where the footer has no Start affordance and the new file could
    /// never run. A genuine unresolved failure or problem still wins over this and reports
    /// `.problems`, same as before — a clean pending row never launders those away.
    static func screenState(jobs: [ToolJob], isRunning: Bool,
                            inspections: [ToolJob.ID: RowInspection],
                            skipped: Set<ToolJob.ID> = []) -> QueueScreenState {
        guard !jobs.isEmpty else { return .empty }
        if isRunning { return .working }
        var hasFailed = false
        var hasTerminal = false
        var hasUnresolvedProblem = false
        var hasCleanPending = false
        for job in jobs {
            switch QueueRowPartition.classify(job: job, inspections: inspections, skipped: skipped) {
            case .delivered, .failedSkipped:
                hasTerminal = true
            case .failedActionable:
                hasTerminal = true
                hasFailed = true
            case .problemUnresolved:
                hasUnresolvedProblem = true
            case .problemSkipped:
                break
            case .cleanPending:
                hasCleanPending = true
            case .cleanSkipped:
                break   // parked by skip, same as a skipped problem row: not runnable, not attention-needing
            case .transient:
                break   // unreachable once `isRunning` is false, kept for exhaustiveness
            }
        }
        guard hasTerminal else { return .ready }
        if hasCleanPending, !hasFailed, !hasUnresolvedProblem { return .ready }
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
        // The modal gate (`QueueView.shouldAcceptDrop`) must be evaluated HERE, synchronously,
        // not inside the async `loadObject` completion below: AppKit reads this return value
        // immediately to decide the drop's accept/reject animation, so returning `true`
        // unconditionally animates acceptance even while the Choose Files/Folder panel is up —
        // the exact case the gate exists for — and silently drops the files with no feedback.
        guard QueueView.shouldAcceptDrop(modalWindowPresented: NSApp.modalWindow != nil) else { return false }
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
