// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import Vision

/// On-device text recognition over one rendered page image (spec §6). Returns Vision's
/// **normalised** bounding boxes verbatim (origin bottom-left, 0…1) — `PDFWriter`, not this
/// type, maps them into PDF user space. Runs entirely on-device (no network), honouring the
/// privacy contract.
struct VisionOCR {

    /// Recognise text in `image`. `options.accuracy` selects the recognition level and
    /// `options.languages` (empty = auto-detect) the recognition languages.
    func recognise(_ image: CGImage, options: OCROptions) async throws -> [PositionedText] {
        try await withCheckedThrowingContinuation { continuation in
            // Vision's request is synchronous CPU/ANE work — run it off the cooperative pool so
            // the ToolQueue concurrency cap stays real (ToolQueue's suspend-on-blocking contract).
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = options.accuracy == .fast ? .fast : .accurate
                request.usesLanguageCorrection = true
                if options.languages.isEmpty {
                    request.automaticallyDetectsLanguage = true
                } else {
                    request.recognitionLanguages = options.languages
                }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let texts = observations.compactMap { observation -> PositionedText? in
                        guard let candidate = observation.topCandidates(1).first,
                              !candidate.string.isEmpty else { return nil }
                        return PositionedText(text: candidate.string, boundingBox: observation.boundingBox)
                    }
                    continuation.resume(returning: texts)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
