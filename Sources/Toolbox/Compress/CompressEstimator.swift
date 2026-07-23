// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Abstracts the PDF analysis calls `CompressEstimator` needs, so tests can inject a
/// slow/misbehaving analyser and exercise the time-box fallback without waiting on real
/// (slow) I/O. `PDFService` conforms via the retroactive extension below — no shared-layer
/// file is touched.
protocol PDFAnalysing {
    func pageCount(_ url: URL) throws -> Int
    func classify(_ url: URL) throws -> PDFContentType
}

extension PDFService: PDFAnalysing {}

enum CompressEstimatorError: Error {
    /// The input is missing, empty, or otherwise unreadable — analysis never starts.
    case unreadable
}

/// Predicts a compressed file's size **before** Ghostscript runs, so the batch UI can show
/// "~2.1 MB" next to a queued file (plan C.1).
///
/// Sample-based: classifies the document (`PDFService.classify`, itself page-sampled) and
/// combines that with an image-payload-ratio heuristic derived from byte density per page —
/// a plain vector/text page runs far below a typical PDF's per-page image payload, so density
/// above that baseline is attributed to embedded images. Time-boxed (default 500 ms — real
/// per-file analysis is milliseconds; the box only guards a pathological/huge input or a
/// slow classifier): on overrun, or on any analysis failure, returns a **typical-range
/// fallback** instead, flagged `isFallback`. The reduction figures are
/// a concrete provisional baseline (mirrors `CompressPreset`'s own baseline) — not corpus-tuned.
struct CompressEstimator {
    private let analyser: PDFAnalysing
    private let timeBudget: TimeInterval

    init(analyser: PDFAnalysing = PDFService(), timeBudget: TimeInterval = 0.5) {
        self.analyser = analyser
        self.timeBudget = timeBudget
    }

    func estimate(_ input: URL, preset: CompressPreset) async -> SizeEstimate {
        await estimateAll(input)[preset] ?? Self.fallbackEstimate(
            inputSize: Self.fileSize(input), preset: preset)
    }

    /// Predictions for EVERY preset, from a single analysis pass.
    ///
    /// The costly part is inspecting the document (page count + content classification); the
    /// per-preset arithmetic is trivial. Doing all three at once means switching preset is a
    /// dictionary lookup rather than a fresh analysis — previously each switch re-analysed every
    /// queued file, blanking the rows into their "analysing" state and making the list appear to
    /// reload on every click.
    func estimateAll(_ input: URL) async -> [CompressPreset: SizeEstimate] {
        let inputSize = Self.fileSize(input)
        let analyser = self.analyser
        let measured = await Self.timeBoxed(seconds: timeBudget) {
            try? Self.measure(input, inputSize: inputSize, analyser: analyser)
        }
        var out: [CompressPreset: SizeEstimate] = [:]
        for preset in CompressPreset.allCases {
            if let measured {
                out[preset] = Self.predict(measured, inputSize: inputSize, preset: preset)
            } else {
                out[preset] = Self.fallbackEstimate(inputSize: inputSize, preset: preset)
            }
        }
        return out
    }

    /// What a single analysis pass yields — preset-independent.
    struct Measurement {
        let contentType: PDFContentType
        let payloadRatio: Double
    }

    private static func measure(_ input: URL, inputSize: Int,
                                analyser: PDFAnalysing) throws -> Measurement {
        guard inputSize > 0 else { throw CompressEstimatorError.unreadable }
        let pageCount = try analyser.pageCount(input)
        let contentType = try analyser.classify(input)
        let bytesPerPage = pageCount > 0 ? Double(inputSize) / Double(pageCount) : Double(inputSize)
        let textBaselineBytesPerPage = 20_000.0
        let payloadRatio = bytesPerPage > textBaselineBytesPerPage
            ? 1.0 - (textBaselineBytesPerPage / bytesPerPage)
            : 0.0
        return Measurement(contentType: contentType, payloadRatio: payloadRatio)
    }

    private static func predict(_ m: Measurement, inputSize: Int,
                                preset: CompressPreset) -> SizeEstimate {
        let base = baseReduction[m.contentType]?[preset] ?? typicalReduction[preset] ?? 0.2
        let reduction = m.contentType == .bornDigital ? base : base * (0.3 + 0.7 * m.payloadRatio)
        let predicted = max(1, Int(Double(inputSize) * (1 - reduction)))
        return SizeEstimate(predictedBytes: predicted, isFallback: false)
    }

    // MARK: sample-based analysis

    private static func analyse(_ input: URL, inputSize: Int, preset: CompressPreset,
                                analyser: PDFAnalysing) throws -> SizeEstimate {
        guard inputSize > 0 else { throw CompressEstimatorError.unreadable }
        let pageCount = try analyser.pageCount(input)
        let contentType = try analyser.classify(input)

        let bytesPerPage = pageCount > 0 ? Double(inputSize) / Double(pageCount) : Double(inputSize)
        // A plain vector/text page runs well under this density; density above it is
        // attributed to embedded image payload, approaching 1.0 as it grows.
        let textBaselineBytesPerPage = 20_000.0
        let payloadRatio = bytesPerPage > textBaselineBytesPerPage
            ? 1.0 - (textBaselineBytesPerPage / bytesPerPage)
            : 0.0

        let base = baseReduction[contentType]?[preset] ?? typicalReduction[preset] ?? 0.2
        // Born-digital text barely varies with image payload (there mostly isn't any); scans
        // and mixed content scale the baseline reduction by how image-heavy the sample is.
        let reduction = contentType == .bornDigital ? base : base * (0.3 + 0.7 * payloadRatio)

        let predicted = max(1, Int(Double(inputSize) * (1 - reduction)))
        return SizeEstimate(predictedBytes: predicted, isFallback: false)
    }

    /// Typical-range fallback (content type unknown/unreliable) — a flat reduction per preset.
    private static func fallbackEstimate(inputSize: Int, preset: CompressPreset) -> SizeEstimate {
        let reduction = typicalReduction[preset] ?? 0.3
        let predicted = max(1, Int(Double(max(inputSize, 1)) * (1 - reduction)))
        return SizeEstimate(predictedBytes: predicted, isFallback: true)
    }

    private static let typicalReduction: [CompressPreset: Double] = [
        .maximumQuality: 0.10,
        .balanced: 0.35,
        .smallestSize: 0.55,
    ]

    private static let baseReduction: [PDFContentType: [CompressPreset: Double]] = [
        .bornDigital: [.maximumQuality: 0.05, .balanced: 0.10, .smallestSize: 0.15],
        .mixedColour: [.maximumQuality: 0.10, .balanced: 0.35, .smallestSize: 0.55],
        .scanColour: [.maximumQuality: 0.12, .balanced: 0.45, .smallestSize: 0.65],
        .scanBilevel: [.maximumQuality: 0.05, .balanced: 0.20, .smallestSize: 0.30],
    ]

    // MARK: time-boxing

    /// Races `work` against a `seconds` deadline on the global dispatch pool — never blocks
    /// the Swift concurrency cooperative pool (mirrors `GhostscriptRunner`'s continuation
    /// bridge) — and returns whichever finishes first. A `work` that overruns keeps running
    /// to completion in the background; its (now-unused) result is simply discarded.
    private static func timeBoxed<T>(seconds: TimeInterval, work: @escaping () -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            DispatchQueue.global(qos: .utility).async { once.resume(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Resumes a checked continuation at most once — whichever of two racing callbacks fires
/// first wins; the other is a no-op.
private final class OnceContinuation<T> {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var resumed = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
