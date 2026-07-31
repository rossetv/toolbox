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
/// checker and the self-updater. `QueueView` constructs its own popovers and sheets against
/// `model` directly; `showAbout` is owned higher still, by `ToolboxApp`, because the app menu's
/// About command toggles the same presentation state as the `⋯` menu's.
struct RootView: View {
    @Binding private var showAbout: Bool
    @StateObject private var model: QueueViewModel
    @StateObject private var updater: SelfUpdater
    @StateObject private var updateChecker = UpdateChecker()

    /// Weak boxes carry the forward reference without a strong retain cycle: `model`'s
    /// `isUpdating` closure reads `updaterBox.value` and `updater`'s `isBusy` closure reads
    /// `modelBox.value`. Neither closure captures the sibling object itself — only this box,
    /// which holds it weakly — so `model` and `updater` don't keep each other alive.
    private let modelBox = WeakBox<QueueViewModel>()
    private let updaterBox = WeakBox<SelfUpdater>()

    /// `_model`/`_updater` must be assigned from an expression that constructs the object
    /// directly inline, not from a local `let` evaluated first: `StateObject`'s `wrappedValue:`
    /// parameter is `@autoclosure`, so only an unevaluated construction expression there is
    /// deferred and run exactly once (on first materialisation of this view's identity). A local
    /// `let m = QueueViewModel(...)` runs the constructor immediately and unconditionally, every
    /// time `RootView.init` runs — i.e. on every `ToolboxApp.body` re-evaluation — re-triggering
    /// `QueueViewModel.init`'s disk side effects (`RunnerUpStore()`, `sweepStale()`) against the
    /// live session and throwing the freshly built object away. Each IIFE below stays inside its
    /// `StateObject`'s autoclosure end to end: it builds the object AND populates that object's
    /// own weak box in the same deferred call, so the box is guaranteed populated by the time
    /// anything on the other side reads it.
    init(showAbout: Binding<Bool>) {
        _showAbout = showAbout
        let modelBox = self.modelBox
        let updaterBox = self.updaterBox
        _model = StateObject(wrappedValue: {
            // `?? true`: a nil box means the interlock isn't wired up yet (only possible during
            // construction) — refuse the racing action rather than silently allow it. Fails
            // closed, never open.
            let m = QueueViewModel(isUpdating: { updaterBox.value?.phase.isActiveUpdate ?? true })
            modelBox.value = m
            return m
        }())
        _updater = StateObject(wrappedValue: {
            let u = SelfUpdater(isBusy: { modelBox.value?.isRunning ?? true })
            updaterBox.value = u
            return u
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let release = updateChecker.available {
                // `isRunning` is passed as a value, not read through the updater's `isBusy`
                // closure: a closure call registers no SwiftUI dependency, so the button would
                // keep looking live until something unrelated redrew the banner.
                UpdateBannerView(release: release, updater: updater, isRunning: model.isRunning)
            }
            QueueView(model: model, history: model.history, showAbout: $showAbout)
        }
        // The content hint alone cannot hold the window open at this size — `.frame` constrains
        // the CONTENT, so a window restored smaller simply clips. `applyMinimumSize` below is
        // the binding constraint: it is the only code that assigns `NSWindow.minSize`.
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { WindowSetup.applyMinimumSize(NSSize(width: 900, height: 640)) }
        .task { await updateChecker.check() }
    }
}

/// A weak, single-slot holder used to pass a not-yet-constructed sibling's eventual reference
/// into a closure without that closure retaining the sibling strongly (see `RootView.init`).
private final class WeakBox<T: AnyObject> {
    weak var value: T?
}
