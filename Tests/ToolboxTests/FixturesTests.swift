// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

final class FixturesTests: XCTestCase {
    func testColourFixturesClassifyAsScanColour() throws {
        XCTAssertEqual(try PDFService().classify(Fixtures.colourTextScanPDF()), .scanColour)
        XCTAssertEqual(try PDFService().classify(Fixtures.colourPhotoScanPDF()), .scanColour)
    }
}
