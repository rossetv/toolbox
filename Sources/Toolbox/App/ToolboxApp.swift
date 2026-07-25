// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless self-test hook (TOOLBOX_SMOKE=compress) — runs the real compress path
        // from the app process and exits, before any window appears.
        CompressSmoke.runIfRequested()
        Self.yieldToExistingInstance()
        // As an XCTest host (the same detection the instance guard uses) the app is
        // scaffolding, not a product: drop to accessory activation so no Dock icon appears
        // and no window steals focus — with parallel testing, every worker clones this
        // host, so a visible host means N Toolbox copies popping up on the developer's Mac.
        if Self.isTestHost {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    /// True when this process is an XCTest host. Matched on ANY `XCTest*` environment key, not
    /// `XCTestConfigurationFilePath` alone: parallel-testing worker clones launch without that
    /// specific key (Xcode passes the configuration out-of-band), and a host mistaken for a user
    /// copy makes the instance guard `exit(0)` mid-suite — the "runner exited with code 0"
    /// failure that killed tests under `-parallel-testing-enabled`.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    /// Single-instance guard. LaunchServices already refuses to launch the same bundle
    /// twice, but a second COPY at another path (an old build in /Applications beside a
    /// fresh one, a mounted DMG) runs happily alongside — two instances writing
    /// `-compressed` siblings into the same folders. The newcomer bows out: bring the
    /// running instance forward and exit before any window appears.
    private static func yieldToExistingInstance() {
        // The hosted XCTest runner launches this app as its test host while a user copy
        // may legitimately be open — killing the host would kill the suite.
        guard !isTestHost,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        // Accessory-activation instances are XCTest hosts (see `init`), not user copies —
        // yielding to one would make a normal launch during a test run silently "open"
        // an invisible scaffolding process instead of a real window.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                      && $0.activationPolicy == .regular }
        // Two copies launched in the same instant can tie (both see each other and both
        // yield, or neither is registered yet and both survive) — unhandled by design:
        // launch-timing-only, no data at risk, a relaunch recovers.
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`. The group hands out File ▸ New Window (⌘N) for
        // free, and a second window builds a second `RootView` — a second `CompressViewModel`
        // sweeping the live runner-up cache, and a second output-name allocator handing out a
        // path the first window has already reserved but not yet written. One window is the same
        // "one allocator, one cache" invariant the instance guard above enforces between copies.
        Window("Toolbox", id: "main") {
            RootView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }
}

/// Closes R15's lifecycle at the other end from `RunnerUpStore.sweepStale()` (launch): empties
/// the runner-up cache on quit, without depending on which view-models are still alive.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        RunnerUpStore.removeAllOnDisk()
    }
}
