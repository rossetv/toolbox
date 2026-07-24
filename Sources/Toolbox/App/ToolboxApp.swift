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
    }

    /// Single-instance guard. LaunchServices already refuses to launch the same bundle
    /// twice, but a second COPY at another path (an old build in /Applications beside a
    /// fresh one, a mounted DMG) runs happily alongside — two instances writing
    /// `-compressed` siblings into the same folders. The newcomer bows out: bring the
    /// running instance forward and exit before any window appears.
    private static func yieldToExistingInstance() {
        // The hosted XCTest runner launches this app as its test host while a user copy
        // may legitimately be open — killing the host would kill the suite.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        // Two copies launched in the same instant can tie (both see each other and both
        // yield, or neither is registered yet and both survive) — unhandled by design:
        // launch-timing-only, no data at risk, a relaunch recovers.
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
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
