// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// A headless self-test for spec §11's EMPIRICAL relaunch verification: with a build
/// installed at `~/Applications/Toolbox.app`, trigger a REAL update against a local fixture
/// server (never live GitHub — see `UpdateChecker`'s `TOOLBOX_UPDATE_FEED` seam) and prove
/// the production relaunch mechanism actually works end to end — the old process exits, a
/// new process of the swapped-in bundle starts and is genuinely the new version. Driven by
/// `scripts/update-smoke-test.sh`; never run by a user and never shipped (this whole file is
/// compiled out of Release builds).
///
/// Two entry points, because `SelfUpdater`'s production relaunch crosses a real process
/// boundary that `open` does NOT carry environment variables across (verified empirically —
/// see the commit that introduced this file): `runIfRequested()` runs in the OLD process and
/// triggers the real update; `checkRelaunchIfMarked()` runs at the very top of every DEBUG
/// launch and detects whether THIS launch is the relaunched instance — via a marker file on
/// disk, since `TOOLBOX_SMOKE`/`TOOLBOX_UPDATE_FEED` set for the old process's launch never
/// reach the new one. Both exit before `RootView` ever appears, so neither launch can trigger
/// the app's normal auto-update-check network request during verification.
#if DEBUG
enum UpdateSmoke {
    /// Anchored under the home directory, not `FileManager.default.temporaryDirectory`: the
    /// latter honours `$TMPDIR`, and the old process (launched directly, inheriting this
    /// script's environment) and the relaunched one (launched by LaunchServices, a different
    /// environment entirely) are not guaranteed to agree on it. Both processes must compute
    /// the exact same path for the marker to cross the process boundary at all.
    private static let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.toolbox.app", isDirectory: true)
    private static let markerURL = stateDirectory.appendingPathComponent("update-smoke.marker")
    private static let resultLogURL = stateDirectory.appendingPathComponent("update-smoke-result.log")

    /// The same XCTest-host detection `ToolboxApp.isTestHost` uses, duplicated rather than
    /// shared across types: a stray marker must never be able to `exit()` a parallelised
    /// test-runner worker mid-suite.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    /// A marker older than this is treated as abandoned — e.g. the relaunch helper's `open`
    /// call failed silently — rather than matched against the current launch. Without this,
    /// a stale marker left by a broken run would silently swallow some later, entirely
    /// unrelated manual launch of the same Debug build (the marker match would compare equal
    /// versions, decide "the relaunch failed", and exit — denying a normal launch).
    private static let markerFreshnessWindow: TimeInterval = 60

    // MARK: - Old process: trigger the real update

    static func runIfRequested() {
        guard !isTestHost,
              ProcessInfo.processInfo.environment["TOOLBOX_SMOKE"] == "update" else { return }
        guard let feedRaw = ProcessInfo.processInfo.environment["TOOLBOX_UPDATE_FEED"],
              URL(string: feedRaw) != nil else {
            FileHandle.standardError.write(Data("UPDATE-SMOKE FAIL: TOOLBOX_UPDATE_FEED not set\n".utf8))
            exit(1)
        }

        var finished = false
        var exitCode: Int32 = 1
        Task { @MainActor in
            exitCode = await run()
            finished = true
        }
        // Pumped, never blocked: `SelfUpdater`/`UpdateChecker` are `@MainActor`, and this
        // runs before SwiftUI's own run loop starts. A raw semaphore wait here would starve
        // the main dispatch queue those actors need to make progress on and deadlock forever
        // — `RunLoop.main.run(until:)` services that queue while we wait synchronously.
        let deadline = Date().addingTimeInterval(120)
        while !finished {
            guard Date() < deadline else {
                FileHandle.standardError.write(Data("UPDATE-SMOKE TIMEOUT\n".utf8))
                exit(1)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    @MainActor
    private static func run() async -> Int32 {
        let oldVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        // No explicit `fetchLatest` closure: the default reads `TOOLBOX_UPDATE_FEED` itself
        // (the same production seam `RootView`'s checker would use), so this exercises the
        // real code path rather than a smoke-only stand-in.
        let checker = UpdateChecker()
        // "0" so ANY release the fixture feed parses to counts as newer, regardless of which
        // version number this particular Debug build happens to carry.
        await checker.check(currentVersion: "0")
        guard let release = checker.available else {
            FileHandle.standardError.write(Data("UPDATE-SMOKE FAIL: feed did not yield a release\n".utf8))
            return 1
        }
        print("UPDATE-SMOKE: release \(release.version) found, dmgURL=\(release.dmgURL?.absoluteString ?? "nil")")

        let updater = SelfUpdater(isBusy: { false }, relaunch: { url in
            // Written ONLY here — the exact instant a real relaunch is about to fire — so a
            // failure earlier in the flow (download, checksum, install) never leaves a
            // marker behind for some later, unrelated launch to misread.
            writeMarker(oldVersion: oldVersion)
            // Spawns the SAME helper process, built from the SAME relaunchArguments, that the
            // shipped app uses — the wait-for-exit-then-open mechanism this whole smoke test
            // exists to verify (already covered directly, with a stand-in for `open`, by
            // SelfUpdaterTests.testRelaunchHelperWaitsForTheProcessToExitBeforeActing).
            // Deliberately NOT `SelfUpdater.relaunchAndTerminate`: that also calls
            // `NSApp.terminate(nil)`, which crashes here (SIGTRAP) — this harness runs
            // headless, from inside ToolboxApp.init(), before SwiftUI ever starts
            // NSApplication's run loop, and AppKit's termination sequence assumes that loop
            // is already active. That is a limitation of running headless before the loop
            // starts, not a gap in what's verified: this process calling `exit()` below ends
            // it exactly as validly, for spec §11's "the old instance exits" assertion, as
            // the production NSApp.terminate(nil) would in a normally-running app.
            try? SystemTool.launchDetached("/bin/sh", SelfUpdater.relaunchArguments(
                pid: ProcessInfo.processInfo.processIdentifier, bundle: url))
        })
        await updater.update(release: release)

        guard case .relaunching = updater.phase else {
            FileHandle.standardError.write(Data("UPDATE-SMOKE FAIL: phase \(updater.phase)\n".utf8))
            return 1
        }
        print("UPDATE-SMOKE PASS: relaunching to \(release.version)")
        return 0
    }

    private static func writeMarker(oldVersion: String) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let payload = "\(oldVersion)|\(Date().timeIntervalSince1970)"
        try? Data(payload.utf8).write(to: markerURL, options: .atomic)
    }

    // MARK: - New process: detect the relaunch

    /// Called unconditionally at the top of every DEBUG launch, before anything else. If a
    /// fresh marker is present, THIS is (almost certainly) the relaunched instance: compare
    /// versions, write the result to `resultLogURL` — stdout is unreachable here, since
    /// `open` does not connect this process's output to anything the driving script can read
    /// — and exit, never falling through to `RootView`, which would otherwise make the app's
    /// normal auto-update-check request against the real GitHub API.
    static func checkRelaunchIfMarked() {
        guard !isTestHost,
              let data = try? Data(contentsOf: markerURL),
              let text = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: markerURL)

        let parts = text.split(separator: "|")
        guard parts.count == 2, let writtenAt = Double(parts[1]),
              Date().timeIntervalSince1970 - writtenAt <= markerFreshnessWindow else { return }
        let recordedOldVersion = String(parts[0])
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        let line: String
        let code: Int32
        if current != recordedOldVersion {
            line = "UPDATE-SMOKE RELAUNCHED: now running \(current) (was \(recordedOldVersion))\n"
            code = 0
        } else {
            line = "UPDATE-SMOKE RELAUNCH-FAIL: still running \(current)\n"
            code = 1
        }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: resultLogURL, options: .atomic)
        exit(code)
    }
}
#endif
