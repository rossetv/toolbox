// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The window's single pane (handoff: "the window is one thing"): the update banner, when a
/// newer release exists, above the unified queue.
///
/// This is where the app's long-lived objects are owned — the queue view model, the update
/// checker and the self-updater — and where `QueueView`'s frozen nine-slot seam is plugged:
/// the queue composes none of its own popovers or sheets, so every one of them is constructed
/// here against the single `model` instance. `showAbout` is owned higher still, by `ToolboxApp`,
/// because the app menu's About command toggles the same presentation state as the `⋯` menu's.
struct RootView: View {
    @Binding private var showAbout: Bool
    @StateObject private var model: QueueViewModel
    @StateObject private var updater: SelfUpdater
    @StateObject private var updateChecker = UpdateChecker()

    /// The view model and the updater are built here rather than in property initialisers
    /// because the updater closes over the model: a property's initial-value expression cannot
    /// reference a sibling property, so the model is built as a local first and both wrappers
    /// are assigned from it.
    init(showAbout: Binding<Bool>) {
        _showAbout = showAbout
        // Forward reference: `m`'s `isUpdating` closure needs `updater`, and `updater`'s `isBusy`
        // closure needs `m` — neither can be built first. `updaterRef` is only ever CALLED once
        // both exist; assigning it right after `m` closes the cycle safely.
        var updaterRef: SelfUpdater!
        let m = QueueViewModel(isUpdating: { updaterRef.phase.isActiveUpdate })
        updaterRef = SelfUpdater(isBusy: { m.isRunning })
        _model   = StateObject(wrappedValue: m)
        _updater = StateObject(wrappedValue: updaterRef)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let release = updateChecker.available {
                // `isRunning` is passed as a value, not read through the updater's `isBusy`
                // closure: a closure call registers no SwiftUI dependency, so the button would
                // keep looking live until something unrelated redrew the banner.
                UpdateBannerView(release: release, updater: updater, isRunning: model.isRunning)
            }
            QueueView(
                model: model, history: model.history,
                quality: { AnyView(QualityPopover(model: model)) },
                ocrOptions: { AnyView(OCRPopover(model: model)) },
                perFile: { AnyView(PerFileSettingsPopover(model: model, jobID: $0)) },
                versions: { AnyView(VersionsPopoverContent(model: model, jobID: $0)) },
                changeQuality: { AnyView(ChangeQualitySheet(model: model)) },
                scanConsent: { AnyView(ScanConsentSheet(model: model, jobID: $0)) },
                recentBatches: { AnyView(RecentBatchesSheet(history: model.history)) },
                about: { AnyView(AboutView()) },
                showAbout: $showAbout
            )
        }
        // The content hint alone cannot hold the window open at this size — `.frame` constrains
        // the CONTENT, so a window restored smaller simply clips. `applyMinimumSize` below is
        // the binding constraint: it is the only code that assigns `NSWindow.minSize`.
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { WindowSetup.applyMinimumSize(NSSize(width: 900, height: 640)) }
        .task { await updateChecker.check() }
    }
}
