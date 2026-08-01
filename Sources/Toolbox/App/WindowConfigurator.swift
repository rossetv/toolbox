// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit

/// Enforces the window's minimum size on the `NSWindow` itself.
///
/// SwiftUI's `.frame(minWidth:minHeight:)` constrains the CONTENT, not the window: a window that
/// opens (or is restored from a previous session) smaller than that simply clips. That is exactly
/// how this app shipped when it still had a `NavigationSplitView`: the sidebar collapsed to zero
/// width and the detail pane was pushed up under the titlebar, an apparently empty sidebar on a
/// window a few hundred points too small. Setting `NSWindow.minSize` makes the constraint real,
/// and growing an already-too-small frame repairs a bad restored size on launch — still needed
/// today even though `RootView` is now a plain `VStack` with no sidebar to collapse.
///
/// Deliberately a plain function rather than an `NSViewRepresentable` placed in `.background`:
/// a representable participates in SwiftUI's layout and displaced the sidebar list upwards by a
/// titlebar's height. Reaching for the window directly has no layout effect at all.
enum WindowSetup {

    /// Size the window opens at when the user has never resized it.
    ///
    /// `.defaultSize` on the `WindowGroup` is only a hint and loses to the content: the detail pane
    /// takes `maxHeight: .infinity`, so SwiftUI is happy to open a window most of the display tall.
    /// Applying a frame here is the only way to make the initial size stick.
    static let preferredSize = NSSize(width: 900, height: 640)

    private static let autosaveName = "ToolboxMainWindow"

    /// Keeps the main window from ever showing an unrequested keyboard focus ring — the
    /// recurring "stray blue square". The invariant: **only keyboard-driven focus may stand.**
    /// AppKit hands first responder to the first focusable control on every path that is not a
    /// key press — the window becoming key again, a sheet closing, a POPOVER closing (which
    /// never takes key status itself, so a key-transition observer misses that path entirely;
    /// it was exactly how the ring around the sidebar header resurrected), app reactivation.
    /// Watching the responder itself catches every such path at the source: an assignment whose
    /// current event is not a key press is cleared a turn later. Tab/arrow navigation arrives
    /// as `.keyDown` and survives, rings and all, per DESIGN.md §6.
    ///
    /// Costs, taken deliberately: focus POSITION (never the rings) is lost on non-key paths,
    /// so Tab restarts from the top after e.g. ⌘-Tab away and back; and a future text field
    /// focused by mouse click would need an exemption here — today the main window has none.
    private static var responderObservation: NSKeyValueObservation?
    private static weak var observedWindow: NSWindow?

    /// Arms the net for whatever main-capable window becomes key — `applyMinimumSize` only runs
    /// from `RootView.onAppear`, which SwiftUI does NOT re-fire for a Dock-reopened window (the
    /// scene content survives the window), so without this a reopened window would never be
    /// re-armed. Verified live: the reopened window showed the ring until this observer existed.
    private static var armingObserver: NSObjectProtocol?

    private static func installArmingObserver() {
        guard armingObserver == nil else { return }
        armingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.canBecomeMain, window.contentView != nil else { return }
            installStrayFocusClear(on: window)
        }
    }

    private static func installStrayFocusClear(on window: NSWindow) {
        // Keyed to the window instance, not a one-shot: closing the window and reopening it
        // from the Dock creates a NEW NSWindow, and an observation still bound to the dead one
        // would silently leave the fresh window outside the net.
        guard observedWindow !== window else { return }
        responderObservation?.invalidate()
        observedWindow = window
        // A fresh window auto-focuses its first control at order-front, BEFORE this watch
        // attaches — clear that pre-arm assignment once, deferred past the current event.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
        responderObservation = window.observe(\.firstResponder) { window, _ in
            guard let responder = window.firstResponder, responder !== window else { return }
            if NSApp.currentEvent?.type == .keyDown { return }
            // Deferred one turn: AppKit is mid-assignment when the observation fires, and a
            // synchronous clear can be overwritten by the very change it reacts to.
            DispatchQueue.main.async {
                // A key press may have moved focus legitimately in the meantime — leave that.
                guard window.firstResponder === responder else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    static func applyMinimumSize(_ minSize: NSSize) {
        installArmingObserver()
        DispatchQueue.main.async {
            for window in NSApp.windows where window.contentView != nil && window.canBecomeMain {
                window.minSize = minSize

                // Adopt the user's remembered size if there is one, and otherwise open at
                // `preferredSize` — once. Checking for the saved frame BEFORE naming the window is
                // what keeps this from overriding a size the user chose themselves.
                if window.frameAutosaveName != autosaveName {
                    let key = "NSWindow Frame \(autosaveName)"
                    let hasSavedFrame = UserDefaults.standard.string(forKey: key) != nil
                    // The result (false when another window already owns the name) is ignored:
                    // the app declares a single `Window` scene, so there is never a second one
                    // to lose the race.
                    window.setFrameAutosaveName(autosaveName)
                    if !hasSavedFrame {
                        var initial = window.frame
                        initial.origin.y += initial.height - preferredSize.height
                        initial.size = preferredSize
                        window.setFrame(initial, display: true, animate: false)
                        window.center()
                    }
                }
                // Outside the naming branch: the net keys on window identity, so every pass
                // re-arms it for whatever window currently exists (Dock reopen creates a new one).
                installStrayFocusClear(on: window)
                // Name the window for the app, not the selected tool: the detail views used to
                // set it and it read "Compress"/"OCR", which says nothing about what is running.
                window.title = "Toolbox"
                // The unified queue's header (`QueueHeaderView`) does not inset itself for the
                // titlebar, so with a full-size content view it draws a titlebar's height too
                // high — over the traffic lights, with its top row obscured.
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false

                // Start with nothing focused. On a cold launch the window opens on the empty
                // state, whose only control is the "Choose Files…" button — auto-focusing it
                // would draw an unrequested keyboard focus ring the instant the window appears.
                // Keyboard users are unaffected: Tab still moves focus and every control still
                // shows its ring, per DESIGN.md.
                window.makeFirstResponder(nil)

                var frame = window.frame
                guard frame.width < minSize.width || frame.height < minSize.height else { continue }
                let grown = NSSize(width: max(frame.width, minSize.width),
                                   height: max(frame.height, minSize.height))
                // AppKit origins are bottom-left: drop the origin by the height gained so the
                // window grows downwards and its titlebar stays put.
                frame.origin.y -= grown.height - frame.height
                frame.size = grown
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}
