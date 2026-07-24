// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit
@testable import Toolbox

/// Shared test helpers.
///
/// Note on locating gs: tests construct `GhostscriptRunner()` so gs resolves via
/// `Bundle.main` to the copy **bundled inside the hosted test app** (under
/// `~/Library/Developer/Xcode/DerivedData/…`). They must NOT run the repo's
/// `Resources/ghostscript/bin/gs` directly: the repo lives under `~/Documents`, a
/// TCC-protected location, and a non-interactive xctest process launching a binary
/// there stalls indefinitely on a TCC decision (empirically verified). The bundled
/// path is both TCC-safe and the real production path (`Bundle.main`).
enum TestSupport {
    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// A stub gs runner that writes a chosen, valid PDF payload to gs's `-sOutputFile=` path — the
    /// gs candidate whose byte count the D7/Rung-2 size gate weighs a rebuild against. Never
    /// launches a process. A copy of the input makes a *large* candidate (the rebuild beats it); a
    /// `tinyValidPDF` makes a *tiny* one (the rebuild loses).
    struct BytesRunner: GhostscriptRunning {
        let bytes: Data
        func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                 onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
            if let path = arguments.first(where: { $0.hasPrefix("-sOutputFile=") })
                .map({ String($0.dropFirst("-sOutputFile=".count)) }) {
                try bytes.write(to: URL(fileURLWithPath: path))
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    /// A genuinely small yet valid PDF that mirrors `input`'s pages: each page rendered at low DPI
    /// and JPEG-encoded, composed through the production `MRCComposer`. Small enough (single-figure
    /// KB) to lose a size gate against a real rebuild, while preserving each page's ink ratio so it
    /// passes `OutputValidator` on the gs delivery path. Page count matches the input.
    static func tinyValidPDF(matching input: URL,
                             maxDimension: CGFloat = 300, quality: Double = 0.4) throws -> Data {
        struct MissingPage: Error {}
        let service = PDFService()
        guard let document = PDFDocument(url: input) else { throw MissingPage() }
        var pages: [MRCComposer.Page] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw MissingPage() }
            let image = try service.render(page, maxDimension: maxDimension)
            guard let jpeg = MRCPageEncoder.encodeJPEG(image, quality: quality) else { throw MissingPage() }
            // Mirror production: the render is upright, so the page uses the displayed size and no `/Rotate`.
            pages.append(MRCComposer.Page(
                content: .jpeg(jpeg),
                size: PDFWriter.displayedSize(mediaBox: page.bounds(for: .mediaBox),
                                              rotation: page.rotation)))
        }
        return try MRCComposer.compose(pages: pages)
    }
}
