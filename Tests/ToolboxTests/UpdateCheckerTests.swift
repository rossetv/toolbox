// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testNewerVersionsAreDetected() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.1"), "components compare numerically, not lexically")
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0.1", than: "0.1.0"), "extra remote component counts")
    }

    func testEqualAndOlderVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"), "missing components read as zero")
        XCTAssertFalse(UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0.1"))
    }

    func testJunkRemoteVersionNeverRaisesTheBanner() {
        XCTAssertFalse(UpdateChecker.isNewer("latest", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0-beta", than: "0.1.0"))
    }

    func testJunkLocalVersionFailsOpen() {
        // Hiding updates forever is the unrecoverable outcome; a spurious banner is not.
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0", than: "garbage"))
    }

    // MARK: - Payload parsing

    private func payload(tag: String, url: String) -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "\#(url)", "assets": []}"#.utf8)
    }

    func testParsesTagAndStripsLeadingV() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(
            payload(tag: "v0.2.0", url: "https://github.com/rossetv/toolbox/releases/tag/v0.2.0")))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.pageURL.host, "github.com")
    }

    func testRejectsMalformedPayloads() {
        XCTAssertNil(UpdateChecker.parseRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(payload(tag: "v", url: "https://github.com/x")),
                     "a bare 'v' tag is an empty version")
        XCTAssertNil(UpdateChecker.parseRelease(payload(tag: "v0.2.0", url: "http://github.com/x")),
                     "a non-HTTPS page URL must be rejected, not opened")
        XCTAssertNil(UpdateChecker.parseRelease(payload(tag: "v0.2.0", url: "https://evil.example/x")),
                     "the page URL host must be pinned to github.com")
        XCTAssertNil(UpdateChecker.parseRelease(payload(
            tag: "v" + String(repeating: "9", count: 100),
            url: "https://github.com/x")),
                     "an oversized version string must be rejected")
        XCTAssertNil(UpdateChecker.parseRelease(payload(
            tag: "v" + Array(repeating: "1", count: 200).joined(separator: "."),
            url: "https://github.com/x")),
                     "a version with an absurd component count must be rejected")
    }

    // MARK: - End-to-end decision (stubbed network)

    @MainActor
    func testNewerReleaseRaisesTheBanner() async {
        let checker = UpdateChecker(fetchLatest: { [payload = payload(
            tag: "v9.9.9", url: "https://github.com/rossetv/toolbox/releases/tag/v9.9.9")] in payload })
        await checker.check(currentVersion: "0.1.0")
        XCTAssertEqual(checker.available?.version, "9.9.9")
    }

    @MainActor
    func testCurrentVersionRaisesNoBanner() async {
        let checker = UpdateChecker(fetchLatest: { [payload = payload(
            tag: "v0.1.0", url: "https://github.com/rossetv/toolbox/releases/tag/v0.1.0")] in payload })
        await checker.check(currentVersion: "0.1.0")
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testNetworkFailureIsSilent() async {
        let checker = UpdateChecker(fetchLatest: { throw URLError(.notConnectedToInternet) })
        await checker.check(currentVersion: "0.1.0")
        XCTAssertNil(checker.available)
    }
}
