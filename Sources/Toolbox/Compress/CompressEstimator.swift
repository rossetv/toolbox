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
/// fallback** instead, flagged `isFallback`. The reduction figures are a concrete provisional
/// baseline (mirrors `CompressPreset`'s own baseline) except `.scanColour` on the scan-rebuild
/// path, which is measured against the real pipeline (see `scanColourRebuildReduction`).
struct CompressEstimator {
    private let analyser: PDFAnalysing
    private let timeBudget: TimeInterval

    init(analyser: PDFAnalysing = PDFService(), timeBudget: TimeInterval = 0.5) {
        self.analyser = analyser
        self.timeBudget = timeBudget
    }

    /// A single analysis pass's result: the per-preset predictions, and the classification they
    /// were derived from. The classification is nil when the analysis failed or overran its time
    /// box — the estimates are then the typical-range fallback, and any caller that reasons about
    /// the engine path (R16) must not assume one.
    struct Analysis {
        let contentType: PDFContentType?
        let estimates: [CompressPreset: SizeEstimate]
    }

    /// Predictions for EVERY preset, from a single analysis pass.
    ///
    /// The costly part is inspecting the document (page count + content classification); the
    /// per-preset arithmetic is trivial. Doing all three at once means switching preset is a
    /// dictionary lookup rather than a fresh analysis — previously each switch re-analysed every
    /// queued file, blanking the rows into their "analysing" state and making the list appear to
    /// reload on every click.
    ///
    /// - Parameter mrcEligible: the caller's half of `CompressEngine`'s own `wantsMRC` rule —
    ///   the row's `rebuildScan` override, defaulted to `true` where the user has expressed no
    ///   preference. The other two conjuncts (`.scanColour`, and a preset other than
    ///   `.maximumQuality`) are this type's own to apply, because it is the one that classifies
    ///   the document and it prices every preset in a single pass. Deliberately has NO default:
    ///   the opt-out is only honest if every call site states it, and a defaulted parameter is
    ///   how this input silently stops being passed.
    func analyse(_ input: URL, mrcEligible: Bool) async -> Analysis {
        let inputSize = Self.fileSize(input)
        let analyser = self.analyser
        let measured = await Self.timeBoxed(seconds: timeBudget) {
            try? Self.measure(input, inputSize: inputSize, analyser: analyser)
        }
        var out: [CompressPreset: SizeEstimate] = [:]
        for preset in CompressPreset.allCases {
            if let measured {
                out[preset] = Self.predict(measured, inputSize: inputSize, preset: preset,
                                           mrcEligible: mrcEligible)
            } else {
                out[preset] = Self.fallbackEstimate(inputSize: inputSize, preset: preset)
            }
        }
        return Analysis(contentType: measured?.contentType, estimates: out)
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
                                preset: CompressPreset, mrcEligible: Bool) -> SizeEstimate {
        // `CompressEngine.compress`'s own `wantsMRC` conjunction, re-derived from the inputs this
        // type has: the row's opt-out, the classification, and the preset (MRC never runs at
        // `.maximumQuality` — MRC D3). All three, or the document is priced on the gs-only path.
        let rebuilds = mrcEligible && m.contentType == .scanColour && preset != .maximumQuality
        let table = rebuilds ? scanColourRebuildReduction : baseReduction[m.contentType]
        let base = table?[preset] ?? typicalReduction[preset] ?? 0.2
        let reduction = m.contentType == .bornDigital ? base : base * (0.3 + 0.7 * m.payloadRatio)
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

    /// `.scanColour` on the scan-rebuild path (spec §6.7) — the ONE table here MEASURED against
    /// the engine rather than assumed. `baseReduction`'s `.scanColour` row prices the gs-only
    /// path a rebuild opt-out leaves and stays where it was; pricing a rebuilt scan from it made
    /// the design's own figures unreachable, which is the defect §6.7 names.
    ///
    /// Derived by running the real pipeline (bundled gs + the Rung-3 race and its D7 gate) over
    /// the repo's `.scanColour` fixtures and the private corpus, then fitting one untempered
    /// constant per preset to each set's median delivered reduction. The tempered prediction
    /// (`base * (0.3 + 0.7 * payloadRatio)`) lands within ±25% of the measured median for
    /// `.balanced` and within ±15% for `.smallestSize`, relative — no single `.balanced` constant
    /// reaches ±15% on both sets, because the fixtures are raw bitmaps that gs alone crushes ~99%
    /// while a real scan delivers less. `.balanced` is within 1% of the median of the documents
    /// where the hybrid ACTUALLY shipped.
    ///
    /// No `.maximumQuality` entry, and the branch above cannot ask for one: the rebuild never
    /// runs at that preset (MRC D3), so its figure stays the gs-only 0.12 in `baseReduction` —
    /// one home for that number, not two that can drift apart.
    private static let scanColourRebuildReduction: [CompressPreset: Double] = [
        .balanced: 0.82,
        .smallestSize: 0.90,
    ]

    private static let baseReduction: [PDFContentType: [CompressPreset: Double]] = [
        .bornDigital: [.maximumQuality: 0.05, .balanced: 0.10, .smallestSize: 0.15],
        .mixedColour: [.maximumQuality: 0.10, .balanced: 0.35, .smallestSize: 0.55],
        .scanColour: [.maximumQuality: 0.12, .balanced: 0.45, .smallestSize: 0.65],
        .scanBilevel: [.maximumQuality: 0.05, .balanced: 0.20, .smallestSize: 0.30],
    ]

    // MARK: time-boxing

    /// Most analyses that may run at once, process-wide.
    ///
    /// One estimate is scheduled per file the user drops, and an image-dominated document's
    /// analysis holds a full-page raster (`PDFService.classify` renders at 1500 px) while it runs —
    /// so without a bound the peak is set by the drop size, which is exactly the input-scaled
    /// growth every sibling path here bounds by a named constant (`CompressEngine.maxBilevelPixels`,
    /// `maxBilevelPages`, `maxMRCPages`). Same figure as `ToolQueue`'s batch cap, for the same
    /// reason: it is what the machine can genuinely work on at once.
    ///
    /// Consequence to keep in view: the time box below now covers the wait for a slot as well as
    /// the analysis, so a drop far larger than this bound settles on `isFallback` estimates for its
    /// tail. That is the designed degradation — a typical-range prediction shown promptly beats an
    /// exact one that arrives after a thrash.
    static let maxConcurrentEstimates = SystemInfo.performanceCoreCount

    /// The bounded pool every analysis runs on. Static so the bound holds across estimator
    /// instances (each `QueueViewModel` builds its own).
    private static let analysisQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrentEstimates
        queue.qualityOfService = .utility
        return queue
    }()

    /// Races `work` against a `seconds` deadline off the Swift concurrency cooperative pool
    /// (mirrors `GhostscriptRunner`'s continuation bridge) and returns whichever finishes first.
    /// A `work` that overruns keeps running to completion in the background; its (now-unused)
    /// result is simply discarded.
    private static func timeBoxed<T>(seconds: TimeInterval, work: @escaping () -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            analysisQueue.addOperation { once.resume(work()) }
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
