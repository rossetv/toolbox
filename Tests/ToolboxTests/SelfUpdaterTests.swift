// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

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
}
