// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum OCRError: Error, LocalizedError {
    case encrypted
    case corrupt
    case sameInputOutput
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .encrypted: return "The PDF is password-protected."
        case .corrupt: return "The PDF is damaged and cannot be read."
        case .sameInputOutput: return "The output path must differ from the input."
        case .validationFailed: return "The OCR'd PDF failed validation."
        }
    }
}

/// Makes image-only PDFs searchable by adding an invisible Vision text layer (spec §6).
///
/// Per page: pages that already carry extractable text are skipped (`PDFService.pageHasText`);
/// image pages are rendered upright at 300 DPI (**per-page render/release** — survives a
/// 1000-page scan), recognised with `VisionOCR`, and the results handed to `PDFWriter` to embed.
/// Output is written to a temp file **in the output directory** then atomically renamed, and
/// re-validated before success. If every page already had text → `.alreadySearchable`.
struct OCREngine {
    /// Render resolution for OCR. 300 DPI is the spec default (corpus-tunable); it is a single
    /// fixed value today, so it stays a constant rather than a config knob.
    private static let renderDPI: CGFloat = 300

    let service: PDFService
    let vision: VisionOCR
    let writer: PDFWriter
    let validator: OutputValidator

    init(service: PDFService = PDFService(),
         vision: VisionOCR = VisionOCR(),
         writer: PDFWriter = PDFWriter(),
         validator: OutputValidator = OutputValidator()) {
        self.service = service
        self.vision = vision
        self.writer = writer
        self.validator = validator
    }

    func ocr(_ input: URL,
             to output: URL,
             options: OCROptions,
             progress: @escaping (Double) -> Void) async throws -> JobOutcome {
        let input = input.canonical
        let output = output.canonical
        guard input.path != output.path else { throw OCRError.sameInputOutput }

        switch try OpenGuard.inspect(input) {
        case .ok: break
        case .encrypted: throw OCRError.encrypted
        case .corrupt: throw OCRError.corrupt
        }
        guard let doc = PDFDocument(url: input) else { throw OCRError.corrupt }
        let count = doc.pageCount
        guard count > 0 else { throw OCRError.corrupt }

        var pageText: [Int: [PositionedText]] = [:]
        var geometry: [Int: PageGeometry] = [:]
        var skipped = 0
        var ocrPages = 0

        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            geometry[i] = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)

            if service.pageHasText(page) {
                skipped += 1                                   // already searchable — leave it (spec §6)
            } else {
                ocrPages += 1
                if let image = await renderUpright(page, dpi: Self.renderDPI) {
                    let boxes = try await vision.recognise(image, options: options)
                    if !boxes.isEmpty { pageText[i] = boxes }  // blank scans add nothing but still count as OCR'd
                }
            }
            progress(Double(i + 1) / Double(count))
        }

        // Every page already had text → nothing to do.
        guard ocrPages > 0 else { return .alreadySearchable }

        // Temp file in the OUTPUT directory (same volume → atomic rename can't cross-device fail).
        let outputDir = output.deletingLastPathComponent().canonical
        let tempURL = outputDir.appendingPathComponent(".pdftoolbox-\(UUID().uuidString).pdf").canonical
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: tempURL) } }

        try writer.appendTextLayer(to: input, output: tempURL, pageText: pageText, geometry: geometry)
        guard try validator.validate(input: input, output: tempURL) else {
            throw OCRError.validationFailed
        }
        try validateOCROutput(input: input, output: tempURL,
                              textPages: Set(pageText.keys), pageCount: count)
        try FileManager.default.moveItem(at: tempURL, to: output)
        renamed = true
        progress(1.0)
        return .ocrAdded(pages: ocrPages, skipped: skipped)
    }

    /// OCR-specific fail-loud net, run before the output is ever placed.
    ///
    /// The generic `OutputValidator` samples a few pages and is tuned for lossy compression, where
    /// the output legitimately differs. OCR needs stronger guarantees: it appends to an untrusted
    /// file with a hand-rolled incremental-update writer, and a writer that mis-tokenises can emit
    /// a plausible-looking but structurally corrupt document. Any failure here discards the output
    /// and fails that file — a skipped file is always preferable to a silently corrupt one, and it
    /// is the same visible outcome the object-stream limitation already produces.
    private func validateOCROutput(input: URL, output: URL, textPages: Set<Int>, pageCount: Int) throws {
        // 1. The incremental-update invariant, and the strongest check available: the original
        //    file must be the output's verbatim prefix. That proves every original object — and
        //    so every image XObject — is byte-identical, and catches any writer desync that
        //    corrupted the copied region.
        guard try Self.hasVerbatimPrefix(of: input, in: output) else {
            throw OCRError.validationFailed
        }
        // 2. Structure survived the append.
        guard let outDoc = PDFDocument(url: output), outDoc.pageCount == pageCount else {
            throw OCRError.validationFailed
        }
        // 3. Every page we wrote text into must still render AND yield extractable text: rendering
        //    proves the page object still parses, extraction proves the layer actually landed.
        //    Checking all of them (not a sample) is what makes single-page corruption fail loud.
        for i in textPages.sorted() {
            guard let page = outDoc.page(at: i) else { throw OCRError.validationFailed }
            _ = try service.render(page, maxDimension: 200)      // per-page render, then released
            guard !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OCRError.validationFailed
            }
        }
    }

    /// Byte-compares `input` against the head of `output` in bounded chunks — never loads either
    /// file whole, so a large scan cannot blow memory just to be validated.
    static func hasVerbatimPrefix(of input: URL, in output: URL) throws -> Bool {
        let inHandle = try FileHandle(forReadingFrom: input)
        let outHandle = try FileHandle(forReadingFrom: output)
        defer { try? inHandle.close(); try? outHandle.close() }
        let chunkSize = 1 << 20
        while true {
            let expected = try inHandle.read(upToCount: chunkSize) ?? Data()
            if expected.isEmpty { return true }              // consumed the whole original
            let actual = try outHandle.read(upToCount: expected.count) ?? Data()
            if actual != expected { return false }
        }
    }

    /// Render a page **upright** (rotation applied) at `dpi`, one page at a time. Uses
    /// `PDFPage.thumbnail`, which honours `/Rotate` and produces an exactly-sized raster
    /// (`PDFService.render` deliberately renders the unrotated media box and is not reused here).
    /// The render runs off the cooperative pool; the `NSImage` is freed before returning.
    private func renderUpright(_ page: PDFPage, dpi: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image: CGImage? = autoreleasepool {
                    let box = page.bounds(for: .mediaBox)
                    let rotation = ((page.rotation % 360) + 360) % 360
                    let displayed = (rotation == 90 || rotation == 270)
                        ? CGSize(width: box.height, height: box.width)
                        : box.size
                    let scale = dpi / 72.0
                    let size = CGSize(width: (displayed.width * scale).rounded(),
                                      height: (displayed.height * scale).rounded())
                    guard size.width >= 1, size.height >= 1 else { return nil }
                    let thumbnail = page.thumbnail(of: size, for: .mediaBox)
                    return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                continuation.resume(returning: image)
            }
        }
    }
}
