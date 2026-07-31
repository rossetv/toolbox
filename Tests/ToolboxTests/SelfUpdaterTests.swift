// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import Network
import XCTest
@testable import Toolbox

/// Self-updater coverage (spec §6.10). Everything here is served from local fixtures —
/// a DMG built by `hdiutil create` in `setUp`, and a loopback HTTP server. **Never live
/// GitHub**: a test that reaches the real release channel is a test that fails when the
/// network does, and a download the CI machine pays for.
final class SelfUpdaterTests: XCTestCase {

    // MARK: - Release asset parsing

    private func payload(tag: String, url: String, assets: [String]? = []) -> Data {
        let assetsJSON = assets.map { list in
            "[" + list.map { #"{"browser_download_url": "\#($0)"}"# }.joined(separator: ",") + "]"
        }
        let assetsField = assetsJSON.map { #", "assets": \#($0)"# } ?? ""
        return Data(#"{"tag_name": "\#(tag)", "html_url": "\#(url)"\#(assetsField)}"#.utf8)
    }

    private let pageURL = "https://github.com/rossetv/toolbox/releases/tag/v0.2.0"
    private let dmgURL = "https://github.com/rossetv/toolbox/releases/download/v0.2.0/Toolbox.dmg"

    func testParsesTheDmgAssetURL() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(
            payload(tag: "v0.2.0", url: pageURL, assets: [dmgURL])))
        XCTAssertEqual(release.dmgURL?.absoluteString, dmgURL)
    }

    func testFirstDmgAssetWins() throws {
        let second = "https://github.com/rossetv/toolbox/releases/download/v0.2.0/Toolbox-alt.dmg"
        let release = try XCTUnwrap(UpdateChecker.parseRelease(payload(
            tag: "v0.2.0", url: pageURL,
            assets: ["https://github.com/rossetv/toolbox/releases/download/v0.2.0/notes.txt",
                     dmgURL, second])))
        XCTAssertEqual(release.dmgURL?.absoluteString, dmgURL, "install.sh takes the first .dmg asset")
    }

    func testReleaseWithoutADmgAssetStillParses() throws {
        // The banner must still show — the button simply degrades to the release page.
        let release = try XCTUnwrap(UpdateChecker.parseRelease(payload(
            tag: "v0.2.0", url: pageURL,
            assets: ["https://github.com/rossetv/toolbox/releases/download/v0.2.0/Toolbox.zip"])))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertNil(release.dmgURL)
    }

    func testReleaseWithNoAssetsKeyStillParses() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(
            payload(tag: "v0.2.0", url: pageURL, assets: nil)))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertNil(release.dmgURL)
    }

    func testDmgURLIsNilForANonGitHubHost() throws {
        // A compromised API response must not point the downloader at an arbitrary host;
        // dropping the asset degrades to the release page rather than failing the parse.
        let release = try XCTUnwrap(UpdateChecker.parseRelease(payload(
            tag: "v0.2.0", url: pageURL, assets: ["https://evil.example/Toolbox.dmg"])))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertNil(release.dmgURL)
    }

    func testDmgURLIsNilForALookalikeHost() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(payload(
            tag: "v0.2.0", url: pageURL, assets: ["https://github.com.evil.example/Toolbox.dmg"])))
        XCTAssertNil(release.dmgURL, "the host is pinned to github.com exactly, not by suffix")
    }

    func testDmgURLIsNilForANonHTTPSAsset() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(payload(
            tag: "v0.2.0", url: pageURL,
            assets: ["http://github.com/rossetv/toolbox/releases/download/v0.2.0/Toolbox.dmg"])))
        XCTAssertNil(release.dmgURL)
    }

    // MARK: - Fixture DMGs (built once — `hdiutil create` is not cheap)

    private static let newVersion = "9.9.9"
    private static let installedVersion = "0.1.0"
    private static var fixtureRoot: URL!
    private static var goodDMG: URL!
    private static var wrongVersionDMG: URL!
    private static var noAppDMG: URL!
    private static var corruptDMG: URL!
    private static var goodDMGBytes: Data!
    private static var goodDMGChecksumFile: Data!

    override class func setUp() {
        super.setUp()
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelfUpdaterTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fixtureRoot = root
            goodDMG = try makeDMG(named: "good", in: root) { payload in
                try writeApp(at: payload.appendingPathComponent("Toolbox.app"), version: newVersion)
            }
            wrongVersionDMG = try makeDMG(named: "wrong-version", in: root) { payload in
                try writeApp(at: payload.appendingPathComponent("Toolbox.app"), version: "1.2.3")
            }
            noAppDMG = try makeDMG(named: "no-app", in: root) { payload in
                try Data("no app here".utf8).write(to: payload.appendingPathComponent("README.txt"))
            }
            corruptDMG = root.appendingPathComponent("corrupt.dmg")
            try Data(repeating: 0x41, count: 8192).write(to: corruptDMG)
            goodDMGBytes = try Data(contentsOf: goodDMG)
            // The published checksum file, produced exactly as the release workflow produces it.
            goodDMGChecksumFile = try shasumOutput(for: goodDMG)
        } catch {
            fatalError("could not build the fixture DMGs: \(error)")
        }
    }

    override class func tearDown() {
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
        super.tearDown()
    }

    private static func writeApp(at bundle: URL, version: String) throws {
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": version,
                                   "CFBundleIdentifier": "com.toolbox.app.fixture",
                                   "CFBundleExecutable": "Toolbox"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("fixture".utf8).write(to: contents.appendingPathComponent("MacOS/Toolbox"))
    }

    private static func makeDMG(named name: String, in root: URL,
                                payload: (URL) throws -> Void) throws -> URL {
        struct HdiutilFailed: Error { let name: String }
        let source = root.appendingPathComponent("payload-\(name)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try payload(source)
        let dmg = root.appendingPathComponent("\(name).dmg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-volname", "Toolbox", "-srcfolder", source.path,
                             "-ov", "-format", "UDZO", "-quiet", dmg.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HdiutilFailed(name: name) }
        return dmg
    }

    private static func shasumOutput(for file: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: - Scene helpers

    /// An install to update: `<temp>/<folder>/Toolbox.app` at `installedVersion`.
    private func makeInstalledApp(in folder: String = "Applications",
                                  version: String = SelfUpdaterTests.installedVersion) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdaterScene-\(UUID().uuidString)")
        let parent = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bundle = parent.appendingPathComponent("Toolbox.app")
        try Self.writeApp(at: bundle, version: version)
        addTeardownBlock {
            // Restore write permission first: a chmod 0500 parent defeats removal.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: root)
        }
        return bundle
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func release(dmgURL: URL?, version: String = SelfUpdaterTests.newVersion)
        -> UpdateChecker.Release {
        UpdateChecker.Release(
            version: version,
            pageURL: URL(string: "https://github.com/rossetv/toolbox/releases/tag/v\(version)")!,
            dmgURL: dmgURL)
    }

    private func startServer() throws -> FixtureHTTPServer {
        let server = try FixtureHTTPServer()
        addTeardownBlock { server.stop() }
        return server
    }

    /// A server serving the good DMG and its published checksum at the usual paths.
    private func startDMGServer() throws -> FixtureHTTPServer {
        let server = try startServer()
        server.route("/Toolbox.dmg", .init(status: 200, body: Self.goodDMGBytes))
        server.route("/Toolbox.dmg.sha256", .init(status: 200, body: Self.goodDMGChecksumFile))
        return server
    }

    private func testConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Prepended, never replacing: http fixtures still go through the system stack, so the
        // redirect under test is a real 302 off a real socket.
        configuration.protocolClasses = [FixtureHTTPSProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    @MainActor
    private func makeUpdater(bundle: URL, isBusy: @escaping () -> Bool = { false },
                             relaunches: RelaunchLog) -> SelfUpdater {
        SelfUpdater(isBusy: isBusy,
                    sessionConfiguration: testConfiguration(),
                    bundleURL: bundle,
                    relaunch: { relaunches.record($0) })
    }

    // MARK: - The flow, end to end against local fixtures

    @MainActor
    func testSuccessPathInstallsTheNewVersionAndRelaunches() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        let relaunches = RelaunchLog()
        let updater = makeUpdater(bundle: bundle, relaunches: relaunches)

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        XCTAssertEqual(updater.phase, .relaunching)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.newVersion)
        XCTAssertEqual(relaunches.recorded, [bundle], "the relaunch helper gets the installed bundle")
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"],
                       "no staged copy and no aside survive a successful swap")
    }

    @MainActor
    func testPhaseReportsEveryStageTheBannerShows() async throws {
        // Downloading… / Verifying… / Installing… are the banner's button states (spec §6.10):
        // the flow must actually pass through them, in order.
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())
        var seen: [SelfUpdater.Phase] = []
        let observation = updater.$phase.sink { seen.append($0) }
        defer { observation.cancel() }

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        XCTAssertEqual(seen, [.idle, .downloading(0), .verifying, .installing, .relaunching])
    }

    @MainActor
    func testASecondUpdateWhileOneIsRunningIsIgnored() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        let relaunches = RelaunchLog()
        let updater = makeUpdater(bundle: bundle, relaunches: relaunches)
        let available = release(dmgURL: server.url("/Toolbox.dmg"))

        async let first: Void = updater.update(release: available)
        async let second: Void = updater.update(release: available)
        _ = await (first, second)

        XCTAssertEqual(server.servedPaths.filter { $0 == "/Toolbox.dmg" }.count, 1,
                       "one download, not two — a double press must not race the swap")
        XCTAssertEqual(relaunches.recorded.count, 1)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.newVersion)
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"])
    }

    @MainActor
    func testUpdateRefusedWhileBusy() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        let relaunches = RelaunchLog()
        let updater = makeUpdater(bundle: bundle, isBusy: { true }, relaunches: relaunches)

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        XCTAssertEqual(updater.phase, .blockedByRun)
        XCTAssertTrue(server.servedPaths.isEmpty, "nothing is downloaded while a batch runs")
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"],
                       "the filesystem is untouched")
        XCTAssertTrue(relaunches.recorded.isEmpty)
    }

    @MainActor
    func testChecksumMismatchFailsWithoutSwapping() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        server.route("/Toolbox.dmg.sha256",
                     .init(status: 200, body: Data((String(repeating: "a", count: 64) + "  Toolbox.dmg\n").utf8)))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed(_, let asidePath) = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertNil(asidePath)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"])
    }

    @MainActor
    func testMissingChecksumFileFails() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        server.route("/Toolbox.dmg.sha256", .init(status: 404))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
    }

    @MainActor
    func testNonHTTPSRedirectCancelled() async throws {
        let bundle = try makeInstalledApp()
        let insecure = try startServer()      // the second local port the hop points at
        insecure.route("/Toolbox.dmg", .init(status: 200, body: Self.goodDMGBytes))
        let server = try startDMGServer()
        server.route("/Toolbox.dmg", .init(
            status: 302, headers: ["Location": insecure.url("/Toolbox.dmg").absoluteString]))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed(let message, let asidePath) = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertNil(asidePath)
        XCTAssertTrue(message.contains("insecure"), "the message names the reason: \(message)")
        XCTAssertTrue(insecure.servedPaths.isEmpty, "the insecure hop must never be fetched")
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
    }

    @MainActor
    func testHTTPSRedirectFollowed() async throws {
        // GitHub redirects release downloads to release-assets.githubusercontent.com and has
        // changed that host before, so the hop's HOST is deliberately unconstrained (spec §6.10)
        // — this fixture host is not github.com on purpose.
        let bundle = try makeInstalledApp()
        FixtureHTTPSProtocol.reset()
        addTeardownBlock { FixtureHTTPSProtocol.reset() }
        let asset = FixtureHTTPSProtocol.serve(Self.goodDMGBytes, at: "/assets/Toolbox.dmg")
        let server = try startDMGServer()
        server.route("/Toolbox.dmg", .init(status: 302, headers: ["Location": asset.absoluteString]))
        let relaunches = RelaunchLog()
        let updater = makeUpdater(bundle: bundle, relaunches: relaunches)

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        XCTAssertEqual(FixtureHTTPSProtocol.servedPaths, ["/assets/Toolbox.dmg"],
                       "the https hop was followed")
        XCTAssertEqual(updater.phase, .relaunching)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.newVersion)
        XCTAssertEqual(relaunches.recorded, [bundle])
    }

    @MainActor
    func testMountFailureFails() async throws {
        let bundle = try makeInstalledApp()
        let server = try startServer()
        server.route("/Toolbox.dmg", .init(status: 200, body: try Data(contentsOf: Self.corruptDMG)))
        server.route("/Toolbox.dmg.sha256", .init(status: 200, body: try Self.shasumOutput(for: Self.corruptDMG)))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed(_, let asidePath) = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertNil(asidePath)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
    }

    @MainActor
    func testPayloadMissingAppFails() async throws {
        let bundle = try makeInstalledApp()
        let server = try startServer()
        server.route("/Toolbox.dmg", .init(status: 200, body: try Data(contentsOf: Self.noAppDMG)))
        server.route("/Toolbox.dmg.sha256", .init(status: 200, body: try Self.shasumOutput(for: Self.noAppDMG)))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed(let message, _) = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertTrue(message.contains("didn't contain"), message)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"])
    }

    @MainActor
    func testPayloadVersionMismatchFails() async throws {
        let bundle = try makeInstalledApp()
        let server = try startServer()
        server.route("/Toolbox.dmg", .init(status: 200, body: try Data(contentsOf: Self.wrongVersionDMG)))
        server.route("/Toolbox.dmg.sha256",
                     .init(status: 200, body: try Self.shasumOutput(for: Self.wrongVersionDMG)))
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        // The release says 9.9.9; the DMG carries 1.2.3.
        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .failed(let message, _) = updater.phase else {
            return XCTFail("expected a failure, got \(updater.phase)")
        }
        XCTAssertTrue(message.contains("version"), message)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
    }

    @MainActor
    func testInstallOutsideApplicationsDegradesToTheReleasePage() async throws {
        let bundle = try makeInstalledApp(in: "Downloads")
        let server = try startDMGServer()
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: server.url("/Toolbox.dmg")))

        guard case .degradedToReleasePage(let reason) = updater.phase else {
            return XCTFail("expected a degrade, got \(updater.phase)")
        }
        XCTAssertTrue(reason.contains("Applications"), reason)
        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion)
    }

    @MainActor
    func testReleaseWithoutADmgDegradesWithoutTouchingTheNetwork() async throws {
        let bundle = try makeInstalledApp()
        let server = try startDMGServer()
        let updater = makeUpdater(bundle: bundle, relaunches: RelaunchLog())

        await updater.update(release: release(dmgURL: nil))

        guard case .degradedToReleasePage = updater.phase else {
            return XCTFail("expected a degrade, got \(updater.phase)")
        }
        XCTAssertTrue(server.servedPaths.isEmpty)
    }

    // MARK: - Relaunch helper

    /// The helper must WAIT for this process to disappear before opening the new bundle: an
    /// `open` fired while the old instance still lives just activates it and then quits it —
    /// the classic self-update no-op (spec §6.10).
    func testRelaunchHelperWaitsForTheProcessToExitBeforeActing() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaunch-marker-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }

        // A stand-in for the app being replaced.
        let standIn = Process()
        standIn.executableURL = URL(fileURLWithPath: "/bin/sleep")
        standIn.arguments = ["30"]
        try standIn.run()

        // The production argv, with the final `open` swapped for a `touch` so the test never
        // launches an application. Everything under test — the wait loop, the `$1`/`$2` offsets,
        // the quoting — is the shipped script.
        var arguments = SelfUpdater.relaunchArguments(pid: standIn.processIdentifier, bundle: marker)
        arguments[1] = arguments[1].replacingOccurrences(of: "exec open", with: "exec /usr/bin/touch")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        try helper.run()
        addTeardownBlock { if helper.isRunning { helper.terminate() } }

        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the helper acted while the old process was still alive")

        standIn.terminate()
        standIn.waitUntilExit()   // reaped, so `kill -0` stops succeeding

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the helper never acted after the old process exited")
    }

    func testRelaunchArgumentsPassThePathAsAnArgumentNotAsShellText() {
        let awkward = URL(fileURLWithPath: "/Applications/Tool \"box\"; rm -rf x.app")
        let arguments = SelfUpdater.relaunchArguments(pid: 1234, bundle: awkward)
        XCTAssertEqual(arguments.last, awkward.path)
        XCTAssertFalse(arguments[1].contains(awkward.path),
                       "the path must never be interpolated into the script text")
    }

    // MARK: - Install destination

    func testInstallDestinationAcceptsAWritableApplicationsParent() throws {
        let bundle = try makeInstalledApp()
        XCTAssertEqual(SelfUpdater.installDestination(for: bundle), bundle.deletingLastPathComponent())
    }

    func testInstallDestinationRejectsAnythingElse() throws {
        let bundle = try makeInstalledApp(in: "Downloads")
        XCTAssertNil(SelfUpdater.installDestination(for: bundle))
    }

    func testInstallDestinationRejectsAReadOnlyApplicationsFolder() throws {
        let bundle = try makeInstalledApp()
        let parent = bundle.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        XCTAssertNil(SelfUpdater.installDestination(for: bundle))
    }

    // MARK: - Quarantine strip

    func testQuarantineStripFailureAbortsPreSwap() throws {
        struct StripFailed: Error {}
        let bundle = try makeInstalledApp()

        XCTAssertThrowsError(try SelfUpdater.install(
            dmg: Self.goodDMG, expectedVersion: Self.newVersion, bundleURL: bundle,
            clearQuarantine: { _ in throw StripFailed() })) { error in
            guard case SelfUpdater.InstallFailure.failed(let message, let asidePath) = error else {
                return XCTFail("expected an install failure, got \(error)")
            }
            XCTAssertNil(asidePath)
            XCTAssertTrue(message.contains("quarantine"), message)
        }

        XCTAssertEqual(SelfUpdater.bundleVersion(of: bundle), Self.installedVersion,
                       "the current install is untouched — the abort happens before any swap")
        XCTAssertEqual(try contents(of: bundle.deletingLastPathComponent()), ["Toolbox.app"],
                       "the staged copy is cleaned up")
    }

    // MARK: - Aside-swap failure legs (every leg ends with a working install)

    /// The install to replace and a staged replacement beside it, as `install` prepares them.
    private func makeSwapScene() throws -> (installed: URL, staged: URL) {
        let installed = try makeInstalledApp()
        let staged = installed.deletingLastPathComponent().appendingPathComponent(".staged.app")
        try Self.writeApp(at: staged, version: Self.newVersion)
        return (installed, staged)
    }

    func testAsideSwapReplacesTheInstall() throws {
        let (installed, staged) = try makeSwapScene()

        try SelfUpdater.asideSwap(installed: installed, staged: staged)

        XCTAssertEqual(SelfUpdater.bundleVersion(of: installed), Self.newVersion)
        XCTAssertEqual(try contents(of: installed.deletingLastPathComponent()), ["Toolbox.app"],
                       "the aside is deleted only after the second rename succeeds")
    }

    func testAsideSwapLeavesTheInstallWorkingWhenTheFirstRenameFails() throws {
        let (installed, staged) = try makeSwapScene()
        let rename = RenameStub(failingCalls: [1])

        XCTAssertThrowsError(try SelfUpdater.asideSwap(
            installed: installed, staged: staged, rename: rename.rename)) { error in
            guard case SelfUpdater.InstallFailure.failed(_, let asidePath) = error else {
                return XCTFail("expected an install failure, got \(error)")
            }
            XCTAssertNil(asidePath, "nothing was moved aside, so there is no aside to name")
        }

        XCTAssertEqual(SelfUpdater.bundleVersion(of: installed), Self.installedVersion)
        XCTAssertEqual(try contents(of: installed.deletingLastPathComponent()), ["Toolbox.app"])
    }

    func testAsideSwapRestoresTheOldVersionWhenTheSecondRenameFails() throws {
        let (installed, staged) = try makeSwapScene()
        let rename = RenameStub(failingCalls: [2])

        XCTAssertThrowsError(try SelfUpdater.asideSwap(
            installed: installed, staged: staged, rename: rename.rename)) { error in
            guard case SelfUpdater.InstallFailure.failed(_, let asidePath) = error else {
                return XCTFail("expected an install failure, got \(error)")
            }
            XCTAssertNil(asidePath, "the restore worked, so no aside is left to name")
        }

        XCTAssertEqual(SelfUpdater.bundleVersion(of: installed), Self.installedVersion,
                       "the old version is back at the install path")
        XCTAssertEqual(try contents(of: installed.deletingLastPathComponent()), ["Toolbox.app"])
    }

    func testAsideSwapPreservesAndNamesTheAsideWhenTheRestoreFails() throws {
        let (installed, staged) = try makeSwapScene()
        let rename = RenameStub(failingCalls: [2, 3])
        var namedAside: String?

        XCTAssertThrowsError(try SelfUpdater.asideSwap(
            installed: installed, staged: staged, rename: rename.rename)) { error in
            guard case SelfUpdater.InstallFailure.failed(let message, let asidePath) = error else {
                return XCTFail("expected an install failure, got \(error)")
            }
            namedAside = asidePath
            XCTAssertNotNil(asidePath, "the last-resort leg must name where the old version is")
            XCTAssertTrue(message.contains(asidePath ?? "—"), "the message names the aside: \(message)")
        }

        let aside = try XCTUnwrap(namedAside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "the aside is never deleted")
        XCTAssertEqual(SelfUpdater.bundleVersion(of: URL(fileURLWithPath: aside)), Self.installedVersion,
                       "a working install survives, at the named path")
    }

    // MARK: - Banner dismissal (per version)

    /// A UserDefaults suite of this test's own — the app's real domain must never carry test
    /// state, and each run starts clean.
    private func makeStore() throws -> UserDefaults {
        let suite = "toolbox.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return store
    }

    @MainActor
    func testBannerDismissalPersistsPerVersion() throws {
        let store = try makeStore()
        let updater = SelfUpdater(isBusy: { false })
        let banner = UpdateBannerView(release: release(dmgURL: nil, version: "9.9.9"),
                                      updater: updater, store: store)

        XCTAssertFalse(UpdateBannerView.isDismissed(version: "9.9.9", in: store))

        banner.dismiss()

        XCTAssertTrue(UpdateBannerView.isDismissed(version: "9.9.9", in: store),
                      "the × writes through the same key the banner's own reader uses")
    }

    @MainActor
    func testNewerVersionReShowsBanner() throws {
        let store = try makeStore()
        let updater = SelfUpdater(isBusy: { false })
        UpdateBannerView(release: release(dmgURL: nil, version: "9.9.9"),
                         updater: updater, store: store).dismiss()

        XCTAssertFalse(UpdateBannerView.isDismissed(version: "9.9.10", in: store),
                       "dismissal is per version — a newer release raises the banner again")

        UpdateBannerView(release: release(dmgURL: nil, version: "9.9.10"),
                         updater: updater, store: store).dismiss()

        XCTAssertTrue(UpdateBannerView.isDismissed(version: "9.9.10", in: store))
        XCTAssertFalse(UpdateBannerView.isDismissed(version: "9.9.9", in: store),
                       "one key, newest dismissal wins")
    }
}

// MARK: - Fixtures: a loopback HTTP server, an in-process https hop, small recorders

/// A minimal loopback HTTP server. Tests are served entirely from here — a test that reached
/// the real release channel would fail whenever GitHub or the network did, and would download
/// tens of megabytes to prove nothing.
final class FixtureHTTPServer {
    struct Route {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "toolbox.tests.fixture-http")
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var served: [String] = []

    init() throws {
        struct ListenerNotReady: Error {}
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            listener.cancel()
            throw ListenerNotReady()
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func route(_ path: String, _ route: Route) {
        lock.lock(); defer { lock.unlock() }
        routes[path] = route
    }

    var servedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self),
                             on: connection)
            } else if error == nil, !isComplete {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let path = String(requestLine.split(separator: " ").dropFirst().first ?? "/")
        lock.lock()
        served.append(path)
        let route = routes[path]
        lock.unlock()

        let response = route ?? Route(status: 404)
        var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Found")\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n"
        for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Serves the https hop of `testHTTPSRedirectFollowed`, in-process, through the updater's
/// injectable session configuration.
///
/// Why not a second local TLS port: a self-signed loopback certificate would have to be trusted
/// by the updater's own session, and teaching production code to accept an untrusted certificate
/// would destroy the exact anchor these tests exist to protect (spec §6.10 — HTTPS to GitHub is
/// the whole trust model). The 302 that lands here still comes off a real socket, so the
/// redirect decision under test runs through the real URL loading system.
final class FixtureHTTPSProtocol: URLProtocol {
    static let host = "fixture-assets.toolbox.invalid"

    private static let lock = NSLock()
    private static var bodies: [String: Data] = [:]
    private static var served: [String] = []

    static func serve(_ body: Data, at path: String) -> URL {
        lock.lock(); defer { lock.unlock() }
        bodies[path] = body
        return URL(string: "https://\(host)\(path)")!
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodies = [:]
        served = []
    }

    static var servedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let body = Self.bodies[url.path]
        if body != nil { Self.served.append(url.path) }
        Self.lock.unlock()

        guard let body, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records the relaunch the real updater would perform (which terminates the process).
final class RelaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }

    var recorded: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}

/// A rename that fails on chosen calls — the only way to drive the swap's failure legs
/// deterministically (a read-only destination fails the staging copy, long before the swap).
final class RenameStub: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failingCalls: Set<Int>

    init(failingCalls: Set<Int>) { self.failingCalls = failingCalls }

    var rename: @Sendable (URL, URL) throws -> Void {
        { [self] from, to in
            struct RenameFailed: Error {}
            lock.lock()
            calls += 1
            let shouldFail = failingCalls.contains(calls)
            lock.unlock()
            if shouldFail { throw RenameFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }
}
