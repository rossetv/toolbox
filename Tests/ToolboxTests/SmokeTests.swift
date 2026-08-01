// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// Proves the hosted test target is wired (TEST_HOST launches, `@testable import`
/// resolves the app module) before the real engine tests build on top of it.
///
/// Re-targeted at I1b: the original assertion (`Tool.allCases == [.compress, .ocr]`) died with
/// `Tool.swift` itself. The canary's purpose — prove the hosted target links and resolves a
/// real app-module symbol — survives onto a surviving one.
final class SmokeTests: XCTestCase {
    func testHostedTargetResolvesAppModuleSymbols() {
        XCTAssertEqual(CompressPreset.allCases.count, 3)
    }
}
