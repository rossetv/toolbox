// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import CryptoKit
import Foundation

/// The self-update: download the release DMG, verify it, and swap the running app for it
/// (spec §6.10). Every integrity step mirrors `scripts/install.sh` — this is the same install,
/// performed in-app.
///
/// **Trust model, stated plainly**: the DMG is self-signed, so there is no code signature to
/// verify. The whole anchor is HTTPS to GitHub — `UpdateChecker.parseRelease` pins the asset
/// URL to `https` + `github.com`, every redirect hop is forced HTTPS here, and the release's
/// published `.sha256` is checked before the download is used for anything. A compromised
/// GitHub account or release channel means arbitrary code execution; that is accepted and
/// recorded (DECISIONS.md), and revisited when signing lands.
///
/// The redirected HOST is deliberately unconstrained: GitHub serves release assets from
/// `release-assets.githubusercontent.com` today and has changed that host before, so a hop
/// allow-list would break every real download while passing every fixture test.
///
/// Every failure leg ends with a working install on disk — at the install path, or (last
/// resort, when even the restore fails) at the aside path named in the error.
@MainActor
final class SelfUpdater: NSObject, ObservableObject, URLSessionTaskDelegate {

    enum Phase: Equatable {
        case idle
        /// A batch is running: the swap would pull the bundled `gs` out from under it.
        case blockedByRun
        /// Fraction of the DMG downloaded (0…1), driving the banner's progress bar. Real,
        /// never fabricated (v1 §8): computed from bytes received against the response's
        /// Content-Length, published at most every whole percent. Stays 0 for the whole
        /// download when the server declares no length — the banner then shows the stage
        /// label alone, with no bar, rather than a dead empty track.
        case downloading(Double)
        case verifying
        case installing
        /// This install cannot be replaced in place (no `.dmg` asset, or the app does not live
        /// in a writable Applications folder). The banner explains and offers the release page.
        case degradedToReleasePage(reason: String)
        /// `asidePath` is non-nil only in the last-resort leg: the swap failed AND the restore
        /// failed, so the previous version is preserved at that path and named to the user.
        case failed(message: String, asidePath: String?)
        case relaunching

        /// Whether the swap is actually in flight — the OTHER direction of spec §6.10's mutual
        /// exclusion (the queue's `canStart`'s `isUpdating` term): `.idle`, `.failed` and
        /// `.degradedToReleasePage` are all resting states a batch may safely start into, and
        /// `.blockedByRun` means no swap has begun (the update itself was refused).
        var isActiveUpdate: Bool {
            switch self {
            case .downloading, .verifying, .installing, .relaunching: return true
            case .idle, .blockedByRun, .degradedToReleasePage, .failed: return false
            }
        }
    }

    /// A failure of the on-disk half of the update, raised off the main actor and mapped to a
    /// `Phase` by `update(release:)`.
    enum InstallFailure: Error, Equatable {
        case degrade(reason: String)
        case failed(message: String, asidePath: String?)
    }

    @Published private(set) var phase: Phase = .idle

    private let isBusy: () -> Bool
    private let sessionConfiguration: URLSessionConfiguration
    private let bundleURL: URL
    private let allowedApplicationsRoots: [URL]
    private let relaunch: @Sendable (URL) -> Void
    private var isUpdating = false

    /// - Parameters:
    ///   - isBusy: whether a batch is in flight. Wired to the queue's `isRunning`.
    ///   - allowedApplicationsRoots: destinations `installDestination` accepts as the swap
    ///     target (spec §6.10: `/Applications` or `~/Applications`). Overridable only for tests
    ///     — production always uses `SelfUpdater.defaultApplicationsRoots()`.
    ///   - relaunch: launches the installed bundle and quits this instance. Injectable because
    ///     the real one terminates the process — a test host cannot survive it.
    init(isBusy: @escaping () -> Bool,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         bundleURL: URL = Bundle.main.bundleURL,
         allowedApplicationsRoots: [URL] = SelfUpdater.defaultApplicationsRoots(),
         relaunch: @escaping @Sendable (URL) -> Void = { SelfUpdater.relaunchAndTerminate($0) }) {
        self.isBusy = isBusy
        self.sessionConfiguration = sessionConfiguration
        self.bundleURL = bundleURL
        self.allowedApplicationsRoots = allowedApplicationsRoots
        self.relaunch = relaunch
        super.init()
    }

    // MARK: - The flow

    func update(release: UpdateChecker.Release) async {
        // The published phase disables the button, but SwiftUI renders that a turn later: a
        // second press in the same turn would otherwise run a second download and a second
        // swap over the top of the first.
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Before any temp directory or request: a swap mid-batch would pull the bundled gs out
        // from under the running jobs.
        guard !isBusy() else { phase = .blockedByRun; return }
        guard let dmgURL = release.dmgURL else {
            phase = .degradedToReleasePage(
                reason: "This release doesn't publish a download Toolbox can install.")
            return
        }

        phase = .downloading(0)
        // Built here and invalidated on the way out: a stored session holding `self` as its
        // delegate is a retain cycle that outlives the update.
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // Sweep before creating this run's directory: a force-quit mid-download leaks the
        // workdir (its `defer` never runs), and partial DMGs are ~16 MB each. Only entries
        // older than an hour are touched — see `sweepStaleWorkDirectories` for why the
        // single-instance guard alone is not sufficient protection for a sibling's run.
        await Task.detached { Self.sweepStaleWorkDirectories() }.value
        guard let workdir = try? Self.makeWorkDirectory() else {
            phase = .failed(message: "Toolbox couldn't make room for the download.", asidePath: nil)
            return
        }
        defer { try? FileManager.default.removeItem(at: workdir) }

        let dmg = workdir.appendingPathComponent("Toolbox.dmg")
        do {
            try await Self.download(dmgURL, to: dmg, session: session) { [weak self] fraction in
                // Only while still downloading: a refused redirect may already have moved the
                // phase to `.failed`, and a late progress tick must not resurrect the bar.
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        } catch {
            // A refused redirect has already set the specific failure — don't overwrite it
            // with the generic cancellation that follows from `task.cancel()`.
            if case .failed = phase { return }
            phase = .failed(message: "The download didn't finish. Check your connection and try again.",
                            asidePath: nil)
            return
        }

        phase = .verifying
        do {
            let published = try await checksum(for: dmgURL, session: session)
            // Detached, as `install` below: hashing 16+ MB synchronously on the main actor
            // would freeze the banner at the exact moment it claims to be working.
            let digest = try await Task.detached(priority: .userInitiated) {
                try Self.sha256(of: dmg)
            }.value
            guard digest == published else {
                phase = .failed(
                    message: "The download didn't match its published checksum, so Toolbox stopped.",
                    asidePath: nil)
                return
            }
        } catch {
            if case .failed = phase { return }
            phase = .failed(message: "Toolbox couldn't check the download against its checksum.",
                            asidePath: nil)
            return
        }

        phase = .installing
        let expectedVersion = release.version
        let bundle = bundleURL
        let roots = allowedApplicationsRoots
        do {
            let installed = try await Task.detached(priority: .userInitiated) {
                try Self.install(dmg: dmg, expectedVersion: expectedVersion, bundleURL: bundle,
                                  allowedApplicationsRoots: roots)
            }.value
            phase = .relaunching
            relaunch(installed)
        } catch let failure as InstallFailure {
            switch failure {
            case .degrade(let reason):
                phase = .degradedToReleasePage(reason: reason)
            case .failed(let message, let asidePath):
                phase = .failed(message: message, asidePath: asidePath)
            }
        } catch {
            phase = .failed(message: "Toolbox couldn't install the update.", asidePath: nil)
        }
    }

    // MARK: - Network

    /// Follows redirects (as `install.sh` does) but refuses any hop that is not HTTPS.
    ///
    /// Declared `nonisolated` deliberately: the completion-handler form cannot await, and a
    /// `@MainActor`-isolated implementation cannot satisfy a nonisolated requirement — it would
    /// have to hop actors around the security check, racing the decision it exists to make.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https" else {
            task.cancel()
            await MainActor.run {
                self.phase = .failed(
                    message: "The download was redirected to an insecure address, so Toolbox stopped it.",
                    asidePath: nil)
            }
            return nil   // nil = do not follow
        }
        return request
    }

    /// The real DMG is ~15 MB (bundled Ghostscript + app). This is a generous multiple of that,
    /// never a real body size — the redirected host is deliberately unconstrained (see the type
    /// doc), so nothing about the response is trusted before this bound is enforced, exactly as
    /// `maxChecksumResponseBytes` does for the sibling fetch below.
    private nonisolated static let maxDMGBytes = 200_000_000

    /// Deliberately `nonisolated static`, and this is load-bearing, not style: as a
    /// `@MainActor` instance method, `for try await byte in stream` paid two executor hops
    /// through the main thread PER BYTE — measured at 155 KB/s against 40 MB/s off the actor,
    /// which turned a 16 MB DMG into a minutes-long "Downloading…" that reads as hung (two
    /// abandoned partial downloads, at 81% and 52%, were found on disk from force-quits).
    ///
    /// `onProgress` is called in order, at most once per whole percent, with a final `1` once
    /// the body is fully on disk; it is never called when the server declares no
    /// Content-Length — a fraction computed against a guess would be the fabricated progress
    /// the phase doc forbids.
    private nonisolated static func download(
        _ url: URL, to destination: URL, session: URLSession,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(Self.maxDMGBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let total = http.expectedContentLength   // -1 when the server declares no length
        var received = 0
        var lastReported = 0.0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        for try await byte in stream {
            buffer.append(byte)
            received += 1
            if received > Self.maxDMGBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    // `min` guards a lying server that sends more than it declared.
                    let fraction = min(1, Double(received) / Double(total))
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        await onProgress(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        if total > 0, lastReported < 1 {
            await onProgress(1)
        }
    }

    /// A `shasum -a 256` line is ~70 bytes (64 hex chars + separator + filename). This is a
    /// generous multiple of that, never a real body size — the redirect host for this fetch is
    /// deliberately unconstrained (see the type doc), so nothing about the response is trusted
    /// before this bound is enforced.
    private static let maxChecksumResponseBytes = 4096

    /// The published checksum, from `<dmg URL>.sha256` — `install.sh`'s own derivation, not a
    /// URL taken from the API payload.
    private func checksum(for dmgURL: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: dmgURL.appendingPathExtension("sha256"))
        request.timeoutInterval = 30
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200
        else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(Self.maxChecksumResponseBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(min(Self.maxChecksumResponseBytes, 256))
        for try await byte in stream {
            data.append(byte)
            if data.count > Self.maxChecksumResponseBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        guard let text = String(data: data, encoding: .utf8),
              // `shasum -a 256` prints "<hex>  <name>"; a bare hex digest is also accepted.
              let digest = text.split(whereSeparator: \.isWhitespace).first.map(String.init),
              digest.count == 64,
              digest.allSatisfy(\.isHexDigit)
        else { throw URLError(.cannotParseResponse) }
        return digest.lowercased()
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    /// Mount → validate payload → destination → stage → quarantine → aside-swap → detach.
    /// Returns the installed bundle. Runs off the main actor: every step shells out.
    ///
    /// `clearQuarantine` and `rename` are injected only so the failure legs can be driven
    /// deterministically — a strip that fails, a rename that fails — which is the only way to
    /// prove the spec's invariant that every leg leaves a working install on disk.
    nonisolated static func install(
        dmg: URL,
        expectedVersion: String,
        bundleURL: URL,
        allowedApplicationsRoots: [URL] = SelfUpdater.defaultApplicationsRoots(),
        clearQuarantine: @Sendable (URL) throws -> Void = { try SelfUpdater.clearQuarantineIfNeeded($0) },
        rename: @Sendable (URL, URL) throws -> Void = { try SelfUpdater.moveItem($0, $1) }
    ) throws -> URL {
        let mount = try mountDMG(dmg)
        // Best-effort, as install.sh: a busy volume must never fail a completed install.
        defer { detach(mount) }

        let payload = mount.appendingPathComponent("Toolbox.app")
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw InstallFailure.failed(message: "The download didn't contain Toolbox.", asidePath: nil)
        }
        guard bundleVersion(of: payload) == expectedVersion else {
            throw InstallFailure.failed(
                message: "The download wasn't the version Toolbox expected, so it was left alone.",
                asidePath: nil)
        }
        guard let destination = installDestination(for: bundleURL, allowedRoots: allowedApplicationsRoots) else {
            throw InstallFailure.degrade(
                reason: "Toolbox isn't running from an Applications folder it can write to, so it can't replace itself here.")
        }

        // Staged on the destination volume, so the swap below is a same-volume rename.
        let staged = destination.appendingPathComponent(".Toolbox-\(UUID().uuidString).staged.app")
        do {
            try ditto(payload, to: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw InstallFailure.failed(message: "Toolbox couldn't copy the new version into place.",
                                        asidePath: nil)
        }

        // On the STAGED copy, before any swap: a failed strip aborts here, current install untouched.
        do {
            try clearQuarantine(staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw InstallFailure.failed(
                message: "Toolbox couldn't clear the download's quarantine flag, so it stopped before changing anything.",
                asidePath: nil)
        }

        try asideSwap(installed: bundleURL, staged: staged, rename: rename)
        return bundleURL
    }

    /// Rename the current bundle aside, rename the staged one into place, and only then delete
    /// the aside. Never rm-then-move: at no instant is there no working app at the install path.
    nonisolated static func asideSwap(
        installed: URL,
        staged: URL,
        rename: @Sendable (URL, URL) throws -> Void = { try SelfUpdater.moveItem($0, $1) }
    ) throws {
        let aside = installed.deletingLastPathComponent()
            .appendingPathComponent(".Toolbox-\(UUID().uuidString).aside.app")
        do {
            try rename(installed, aside)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw InstallFailure.failed(
                message: "Toolbox couldn't move the current version aside, so nothing was changed.",
                asidePath: nil)
        }
        do {
            try rename(staged, installed)
        } catch {
            do {
                try rename(aside, installed)
            } catch {
                // Last resort: the ASIDE is never deleted (it's the only known-good copy left),
                // but the staged copy is — same as every other failure leg — so a failed rename
                // never leaves a hidden, quarantine-stripped bundle behind with no sweeper.
                try? FileManager.default.removeItem(at: staged)
                throw InstallFailure.failed(
                    message: "Toolbox couldn't install the update or put the old version back. "
                        + "Your previous version is safe at \(aside.path) — move it to \(installed.path).",
                    asidePath: aside.path)
            }
            try? FileManager.default.removeItem(at: staged)
            throw InstallFailure.failed(
                message: "Toolbox couldn't install the update. The version you had is still in place.",
                asidePath: nil)
        }
        try? FileManager.default.removeItem(at: aside)
    }

    /// The directory to install into: the running bundle's parent, when that parent is exactly
    /// `/Applications` or `~/Applications` (spec §6.10) and writable. Anything else —
    /// translocated, mounted from the DMG, Downloads, a dev build directory, or any OTHER
    /// directory that merely happens to be named "Applications" — returns nil, and the update
    /// degrades to the release page. `allowedRoots` is overridable for tests only; production
    /// always uses `defaultApplicationsRoots()`.
    nonisolated static func installDestination(
        for bundleURL: URL,
        allowedRoots: [URL] = SelfUpdater.defaultApplicationsRoots()
    ) -> URL? {
        let parent = bundleURL.deletingLastPathComponent().standardizedFileURL
        guard allowedRoots.contains(where: { $0.standardizedFileURL == parent }),
              FileManager.default.isWritableFile(atPath: parent.path) else { return nil }
        return parent
    }

    /// The real destinations spec §6.10 pins: `/Applications` and the user's `~/Applications`.
    nonisolated static func defaultApplicationsRoots() -> [URL] {
        [URL(fileURLWithPath: "/Applications")]
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
    }

    /// `spctl` first, exactly as `install.sh`: strip quarantine only when Gatekeeper rejects the
    /// copy (i.e. it isn't notarised). Throws when the strip itself fails.
    nonisolated static func clearQuarantineIfNeeded(_ bundle: URL) throws {
        struct QuarantineStripFailed: Error {}
        let accepted = (try? SystemTool.run("/usr/sbin/spctl", ["-a", "-t", "exec", bundle.path]).status) == 0
        guard !accepted else { return }
        guard let result = try? SystemTool.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path]),
              result.status == 0 else { throw QuarantineStripFailed() }
    }

    /// Launch a detached helper that waits for this process to exit and then opens the new
    /// bundle, then quit. `open`-then-terminate on its own is the classic no-op: it activates
    /// the still-running instance and then quits it.
    nonisolated static func relaunchAndTerminate(_ bundle: URL) {
        try? SystemTool.launchDetached("/bin/sh", relaunchArguments(
            pid: ProcessInfo.processInfo.processIdentifier, bundle: bundle))
        Task { @MainActor in NSApp.terminate(nil) }
    }

    /// `/bin/sh` argv for the relaunch helper: wait for `pid` to disappear, then open `bundle`.
    /// The PID and the path are arguments (`$1`, `$2`), never interpolated into the script text
    /// — a path with a quote or a space in it must not become shell syntax.
    nonisolated static func relaunchArguments(pid: Int32, bundle: URL) -> [String] {
        ["-c", #"while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#,
         "toolbox-relaunch", String(pid), bundle.path]
    }

    // MARK: - Shell steps

    nonisolated static func moveItem(_ from: URL, _ to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }

    private nonisolated static func mountDMG(_ dmg: URL) throws -> URL {
        // The mount point is PARSED, never assumed: a busy /Volumes/Toolbox silently becomes
        // "/Volumes/Toolbox 1" (install.sh's own lesson).
        guard let result = try? SystemTool.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-plist"]),
              result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw InstallFailure.failed(message: "Toolbox couldn't open the download.", asidePath: nil)
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private nonisolated static func detach(_ mount: URL) {
        _ = try? SystemTool.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
    }

    private nonisolated static func ditto(_ source: URL, to destination: URL) throws {
        struct CopyFailed: Error {}
        let result = try SystemTool.run("/usr/bin/ditto", [source.path, destination.path])
        guard result.status == 0 else { throw CopyFailed() }
    }

    nonisolated static func bundleVersion(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private nonisolated static let workDirectoryPrefix = "Toolbox-update-"

    private nonisolated static func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(workDirectoryPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// How old an abandoned work directory must be before the sweep may take it. Two live
    /// instances can briefly coexist — the single-instance guard's own tie window, and the
    /// DEBUG update smoke runs before that guard is reached — and sweeping a sibling's
    /// in-flight download would surface to its user as a checksum failure for a file this
    /// process deleted. An in-flight run's directory is minutes old at most; the leaks this
    /// sweep exists for are hours-to-days old.
    private nonisolated static let sweepMinimumAge: TimeInterval = 3600

    /// Remove work directories abandoned by earlier runs — a force-quit mid-download skips
    /// the owning run's `defer`, and each leak is a partial DMG. Best-effort by design: a
    /// sweep that cannot remove something must never fail the update it precedes.
    private nonisolated static func sweepStaleWorkDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(workDirectoryPrefix) {
            // An unreadable date falls back to NOW — unknown age must fail toward keeping,
            // or the fallback silently defeats the age floor this sweep promises.
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            guard Date().timeIntervalSince(modified) > sweepMinimumAge else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

}

/// The updater's one and only `Process` construction site. CODE_GUIDELINES §2.1 ("Ghostscript
/// runs only through GhostscriptRunner… No other code constructs a Process") predates the
/// self-updater (human decision D1, spec §6.10); these are non-gs system tools
/// (hdiutil/spctl/xattr/sh) outside the seatbelt's remit. §2.1's amendment is pending the
/// maintainer's sign-off — recorded in the PR.
///
/// Every tool path is an absolute literal supplied by the caller; arguments are always passed as
/// an array, never interpolated into a shell string (see `SelfUpdater.relaunchArguments`).
internal enum SystemTool {
    /// Runs `tool`, waits for it to exit, and captures its stdout. stderr is discarded, never
    /// left as an undrained pipe — a full stderr buffer would stall the tool forever.
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let (process, stdout) = try launch(tool, arguments, captureOutput: true)
        let data = stdout!.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Launches `tool` and returns immediately, without waiting for it to exit. Used only for
    /// the relaunch helper, which must outlive this process — `waitUntilExit()` there would
    /// deadlock against the very process it is waiting to relaunch.
    static func launchDetached(_ tool: String, _ arguments: [String]) throws {
        _ = try launch(tool, arguments, captureOutput: false)
    }

    private static func launch(_ tool: String, _ arguments: [String], captureOutput: Bool) throws
        -> (process: Process, stdout: Pipe?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var stdout: Pipe?
        if captureOutput {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            stdout = pipe
        }
        try process.run()
        return (process, stdout)
    }
}
