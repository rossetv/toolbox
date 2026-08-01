// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI
import XCTest
@testable import Toolbox

/// The stray-focus-ring net (memory: 20260725-stray-focus-ring-invariant.md) at the
/// AppKit-mechanism level: `WindowSetup`'s arming observer and its KVO-driven clearing,
/// exercised against real `NSWindow`s. This is NOT the behavioural check — a headless unit test
/// cannot drive AppKit's window server or SwiftUI's own `TapGesture` recognition, so the
/// click-focus half of the invariant (`.clearsClickFocus()`'s own gesture-driven clear) stays
/// V1's protocol: a real popover-close keyboard walk, done by hand (spec §9). What IS testable,
/// and tested here, is that the net's two halves are correctly wired: the arming observer
/// attaches to a window it never saw before, and a real `.plain`-styled control carrying
/// `.clearsClickFocus()` composes correctly with that net once installed.
@MainActor
final class WindowSetupFocusTests: XCTestCase {

    /// `WindowSetup`'s own gate — both `applyMinimumSize`'s install loop and the arming
    /// observer's notification handler require `window.canBecomeMain` — cannot be satisfied by
    /// a stock `NSWindow` in THIS test host: `ToolboxApp.init()` deliberately runs XCTest hosts
    /// at `NSApp.activationPolicy() == .accessory` (so a parallel-testing worker's scaffolding
    /// process never steals focus or shows a Dock icon), and under that policy AppKit's default
    /// `canBecomeMain` heuristic returns `false` for every window regardless of style mask
    /// (verified live: a plain titled/closable/resizable window reported `canBecomeMain == false`
    /// here). Overriding it is a test-only stand-in for the real app's regular-activation main
    /// window — it does not change `WindowSetup`'s gate, only makes this file's probe window
    /// satisfy it the way a real launch would.
    private final class MainCapableTestWindow: NSWindow {
        override var canBecomeMain: Bool { true }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.close() }
        windows = []
        super.tearDown()
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = MainCapableTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                           styleMask: [.titled, .closable, .resizable],
                                           backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        windows.append(window)
        return window
    }

    /// A REAL production control: `MotionButtonStyle()` + `.clearsClickFocus()`, hosted so it
    /// actually accepts first responder (a bare `NSView` does not, by default — an assignment
    /// to one would silently no-op and any assertion built on it would pass for the wrong
    /// reason).
    private func makeClearsClickFocusProbe() -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(
            Button("Probe") {}
                .buttonStyle(MotionButtonStyle())
                .clearsClickFocus()
                .frame(width: 120, height: 32)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 32)
        return host
    }

    /// Pumps the run loop in short bursts, re-checking `condition` between each, until it is
    /// true or `timeout` elapses. Every clearing this file provokes is at least one
    /// `DispatchQueue.main.async` turn away from the assignment that triggers it — a single fixed
    /// hop is exactly the ordering assumption that flakes under the gate's 8-way parallel load.
    @discardableResult
    private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return condition()
    }

    // MARK: - The arming observer

    /// `installArmingObserver` (private) is exercised only through its public entry point,
    /// `applyMinimumSize`, which installs it idempotently. The scenario this proves is the one
    /// `installArmingObserver`'s own doc comment names: a window that becomes key AFTER
    /// `applyMinimumSize` last ran — never present in `NSApp.windows` at that call, so never
    /// touched by its direct install loop — still gets the stray-focus net, because
    /// `RootView.onAppear` does not re-fire for a Dock-reopened window and only the
    /// `didBecomeKeyNotification` watch can re-arm it.
    func testArmingObserverInstallsTheNetOnAWindowItNeverSawBefore() {
        WindowSetup.applyMinimumSize(NSSize(width: 400, height: 300))

        let probe = makeClearsClickFocusProbe()
        let window = makeWindow(content: probe)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        // The arming observer's callback is itself delivered via `queue: .main` — not
        // synchronous with `post` — so give it room to run and attach the KVO watch BEFORE this
        // file assigns focus. Assigning first responder before the watch attaches would test
        // nothing: KVO never retroactively reports a change that predates the observation.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(window.makeFirstResponder(probe),
                      "the probe control must actually accept first responder for this test to "
                      + "prove anything")

        let cleared = poll(timeout: 3) { window.firstResponder !== probe }
        XCTAssertTrue(cleared, "a window that becomes key after applyMinimumSize should still "
                      + "have its non-keyDown first responder cleared by the arming observer's "
                      + "net")
    }

    // MARK: - A `MotionButtonStyle`-styled probe control

    /// The house rule (memory: stray-focus-ring invariant) is "every `MotionButtonStyle`
    /// control gets `.clearsClickFocus()`". This builds a control with that exact incantation
    /// and hosts it for real inside a window `WindowSetup` protects directly (no arming-observer
    /// timing involved — the window exists before `applyMinimumSize` runs, so its net attaches
    /// synchronously), then gives it first responder status directly — standing in for AppKit's
    /// own auto-assignment on window re-key/popover-close, which is what the net exists to catch
    /// — and confirms the net still clears it. This does NOT exercise `.clearsClickFocus()`'s
    /// own `TapGesture`-driven clear (no display server here to recognise a real click); that
    /// leg is V1's manual keyboard walk.
    func testMotionStyledProbeControlLosesNonKeyDownFocusInsideTheNet() {
        let probe = makeClearsClickFocusProbe()
        let window = makeWindow(content: probe)
        probe.layoutSubtreeIfNeeded()

        WindowSetup.applyMinimumSize(NSSize(width: 400, height: 300))

        XCTAssertTrue(window.makeFirstResponder(probe),
                      "the hosted probe control must actually accept first responder for this "
                      + "test to prove anything")

        let cleared = poll(timeout: 3) { window.firstResponder !== probe }
        XCTAssertTrue(cleared, "a MotionButtonStyle-styled, .clearsClickFocus()-carrying control's "
                      + "non-keyDown first responder should be cleared by WindowSetup's net")
    }
}
