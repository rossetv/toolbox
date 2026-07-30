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

/// A one-shot latch: `wait()` suspends until `open()` is called (or returns at once if already
/// open). A latch, not a handoff — the queue and the recompress phase both run up to
/// `performanceCoreCount` engine calls at once, so several callers can be suspended here
/// simultaneously. A single stored continuation would let the second waiter overwrite (and orphan)
/// the first, which is why this holds an array.
actor Gate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

/// Stub `Compressing`: writes the shipped (and, when given, the runner-up) file, optionally
/// suspends on a `Gate`, then returns a fixed outcome. Never touches the real MRC pipeline.
final class StubCompressEngine: Compressing, @unchecked Sendable {
    let outcome: RowOutcome
    let shippedBytes: Int
    let runnerUpBytes: Int
    /// What one scripted call writes and returns, so a recompress can differ from the run that
    /// produced the row.
    struct Response {
        let outcome: RowOutcome
        /// Bytes to write at the primary output, or nil to write nothing (a no-gain run).
        let shippedBytes: Int?
        /// Bytes to write at the alternate output, or nil to leave that slot empty.
        let runnerUpBytes: Int?
    }

    // `compress` runs concurrently: `ToolQueue.execute` fans out up to `performanceCoreCount`
    // jobs at once, so `callCount`, `presets`, `script`, `throwOnCall`, `reportToDeliver` and
    // `gate` all need genuine synchronisation rather than plain mutable state. Everything below
    // the lock keeps the same external API (synchronous property access from @MainActor tests)
    // but is backed by a private, lock-guarded store.
    private let lock = NSLock()
    private var _callCount = 0
    private var _presets: [CompressPreset] = []
    private var _inputs: [URL] = []
    private var _rebuildScans: [Bool?] = []
    private var _script: ((Int, CompressPreset) -> Response)?
    private var _throwOnCall: Int?
    private var _errorToThrow: Error = CompressError.validationFailed
    private var _reportToDeliver: MRCDocumentReport?
    private var _gate: Gate?

    /// Number of `compress` calls made so far.
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    /// Every preset the engine was called with, in order — so a test can assert which one a
    /// re-run reproduced, or which one an overridden row was dispatched at.
    var presets: [CompressPreset] { lock.lock(); defer { lock.unlock() }; return _presets }
    /// Every input the engine was called with, in order — so a concurrent batch's calls can be
    /// attributed to their rows.
    var inputs: [URL] { lock.lock(); defer { lock.unlock() }; return _inputs }
    /// Every `rebuildScan` override the engine was called with, in order.
    var rebuildScans: [Bool?] { lock.lock(); defer { lock.unlock() }; return _rebuildScans }
    /// Per-call script (1-based call index). Nil keeps the fixed outcome the initialiser took.
    var script: ((Int, CompressPreset) -> Response)? {
        get { lock.lock(); defer { lock.unlock() }; return _script }
        set { lock.lock(); defer { lock.unlock() }; _script = newValue }
    }
    /// When set, the engine throws on this 1-based call instead of writing anything.
    var throwOnCall: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _throwOnCall }
        set { lock.lock(); defer { lock.unlock() }; _throwOnCall = newValue }
    }
    /// What `throwOnCall` throws. Defaults to `CompressError.validationFailed`; the compress-failure
    /// rescue distinguishes the compress-specific errors from the rest, so it must be selectable.
    var errorToThrow: Error {
        get { lock.lock(); defer { lock.unlock() }; return _errorToThrow }
        set { lock.lock(); defer { lock.unlock() }; _errorToThrow = newValue }
    }
    /// When set, handed to the caller's `mrcReport` closure — exercises the retention path.
    var reportToDeliver: MRCDocumentReport? {
        get { lock.lock(); defer { lock.unlock() }; return _reportToDeliver }
        set { lock.lock(); defer { lock.unlock() }; _reportToDeliver = newValue }
    }
    var gate: Gate? {
        get { lock.lock(); defer { lock.unlock() }; return _gate }
        set { lock.lock(); defer { lock.unlock() }; _gate = newValue }
    }

    init(outcome: RowOutcome, shippedBytes: Int, runnerUpBytes: Int) {
        self.outcome = outcome
        self.shippedBytes = shippedBytes
        self.runnerUpBytes = runnerUpBytes
    }

    func compress(_ input: URL, preset: CompressPreset, to output: URL,
                  alternateOutput: URL?, rebuildScan: Bool?,
                  mrcReport: ((MRCDocumentReport) -> Void)?,
                  progress: @escaping (Double) -> Void) async throws -> RowOutcome {
        // Increment, append and decide the throw/script outcome atomically, capturing locals so
        // no other concurrent call can observe or mutate state mid-decision.
        let call: Int
        let thrown: Error?
        let currentScript: ((Int, CompressPreset) -> Response)?
        lock.lock()
        _callCount += 1
        _presets.append(preset)
        _inputs.append(input)
        _rebuildScans.append(rebuildScan)
        call = _callCount
        thrown = _throwOnCall == call ? _errorToThrow : nil
        currentScript = _script
        lock.unlock()
        if let thrown { throw thrown }
        let response = currentScript?(call, preset)
            ?? Response(outcome: outcome, shippedBytes: shippedBytes, runnerUpBytes: runnerUpBytes)
        let fm = FileManager.default
        // Mirror the production engine's never-overwrite delivery contract (it `moveItem`s the
        // winner into place, which throws on an existing destination) — a stub that overwrites
        // via `Data.write` would mask a caller that targets an already-occupied destination.
        if let bytes = response.shippedBytes {
            guard !fm.fileExists(atPath: output.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data(repeating: 0x48, count: bytes).write(to: output)
        }
        if let alternateOutput, let bytes = response.runnerUpBytes {
            guard !fm.fileExists(atPath: alternateOutput.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data(repeating: 0x4E, count: bytes).write(to: alternateOutput)
        }
        if let reportToDeliver { mrcReport?(reportToDeliver) }
        if let gate { await gate.wait() }
        return response.outcome
    }
}

/// Stub `OCRing`: hands back a scripted `RecognisedDocument` and, for `append`, copies the target
/// verbatim to the output (a stub cannot embed a real layer, and copying keeps the caller's
/// temp-then-replace delivery exercised end to end).
///
/// Concurrency-aware for the same reason as `StubCompressEngine`: the OCR leg runs inside the
/// batch's task group, so `recognise` can be entered by several jobs at once. `peakConcurrent`
/// records the high-water mark, which is what the width-2 semaphore is asserted against.
final class StubOCREngine: OCRing, @unchecked Sendable {
    private let lock = NSLock()
    private var _recogniseCallCount = 0
    private var _appendCallCount = 0
    private var _appendTargets: [URL] = []
    private var _inFlight = 0
    private var _peakConcurrent = 0
    private var _throwOnRecogniseCall: Int?
    private var _recogniseError: Error = OCRError.validationFailed
    private var _appendShouldThrow = false
    private var _gate: Gate?

    /// The document every `recognise` hands back. No default: a wrong default would decide the
    /// row's `OCROutcome` behind the test's back.
    let document: RecognisedDocument

    init(document: RecognisedDocument) {
        self.document = document
    }

    var recogniseCallCount: Int { lock.lock(); defer { lock.unlock() }; return _recogniseCallCount }
    var appendCallCount: Int { lock.lock(); defer { lock.unlock() }; return _appendCallCount }
    /// Every target `append` was asked to write from, in order — so a test can assert which
    /// variants received the layer.
    var appendTargets: [URL] { lock.lock(); defer { lock.unlock() }; return _appendTargets }
    /// The most `recognise` calls ever in flight at once.
    var peakConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _peakConcurrent }
    /// When set, `recognise` throws on this 1-based call.
    var throwOnRecogniseCall: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _throwOnRecogniseCall }
        set { lock.lock(); defer { lock.unlock() }; _throwOnRecogniseCall = newValue }
    }
    var recogniseError: Error {
        get { lock.lock(); defer { lock.unlock() }; return _recogniseError }
        set { lock.lock(); defer { lock.unlock() }; _recogniseError = newValue }
    }
    /// When true, every `append` throws — the honest "this variant could not carry the layer" path.
    var appendShouldThrow: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _appendShouldThrow }
        set { lock.lock(); defer { lock.unlock() }; _appendShouldThrow = newValue }
    }
    /// Suspends every `recognise` until opened, so a test can hold the OCR leg mid-flight.
    var gate: Gate? {
        get { lock.lock(); defer { lock.unlock() }; return _gate }
        set { lock.lock(); defer { lock.unlock() }; _gate = newValue }
    }

    func recognise(_ input: URL, options: OCROptions,
                   progress: @escaping (Double) -> Void) async throws -> RecognisedDocument {
        let thrown: Error?
        let currentGate: Gate?
        lock.lock()
        _recogniseCallCount += 1
        _inFlight += 1
        _peakConcurrent = max(_peakConcurrent, _inFlight)
        thrown = _throwOnRecogniseCall == _recogniseCallCount ? _recogniseError : nil
        currentGate = _gate
        lock.unlock()
        // Decremented on every exit, throw included: a leaked in-flight count would make the
        // concurrency assertion read high for the rest of the run.
        defer { lock.lock(); _inFlight -= 1; lock.unlock() }
        if let currentGate { await currentGate.wait() }
        if let thrown { throw thrown }
        progress(1)
        return document
    }

    func append(_ recognised: RecognisedDocument, to target: URL, output: URL) throws {
        let shouldThrow: Bool
        lock.lock()
        _appendCallCount += 1
        _appendTargets.append(target)
        shouldThrow = _appendShouldThrow
        lock.unlock()
        if shouldThrow { throw OCRError.validationFailed }
        try FileManager.default.copyItem(at: target, to: output)
    }
}

struct TimedOut: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "condition not met within \(seconds)s" }
}

/// Polls `condition` until true or `timeout` elapses — a genuine timeout is a **test
/// failure** (thrown, not skipped): this guards real async completion, not an
/// environment precondition.
func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            throw TimedOut(seconds: timeout)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
