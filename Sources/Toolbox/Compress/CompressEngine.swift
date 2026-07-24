// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import PDFKit

enum CompressError: Error, LocalizedError {
    case encrypted
    case corrupt
    case sameInputOutput
    case ghostscriptFailed(String)
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .encrypted: return "The PDF is password-protected."
        case .corrupt: return "The PDF is damaged and cannot be read."
        case .sameInputOutput: return "The output path must differ from the input."
        case .ghostscriptFailed(let message): return "Compression failed: \(message)"
        case .validationFailed: return "The compressed PDF failed validation."
        }
    }
}

/// A page attempt that cannot even fall back — the full-page render itself failed, so there is
/// no JPEG to ship. Thrown by `mrcPage` and caught in `mrcCompress`, where it becomes a
/// whole-document decline (D10): a hybrid missing one page is never composed.
private struct MRCDecline: Error {}

/// Rung-1 compression: tuned Ghostscript `pdfwrite`, wholly inside the seatbelt sandbox.
///
/// Safety contract (spec §5.4): inspects the input first (encrypted/corrupt rejected); **stages
/// all gs I/O through a private working dir under the system temp dir** so the seatbelt-sandboxed
/// gs child — which cannot inherit the app's TCC file-access grant — never touches a TCC-protected
/// path (~/Documents, ~/Downloads, ~/Desktop); the result is copied onto the destination volume
/// then **atomically renamed** into place (never overwrites the input; a failure/cancel leaves no
/// partial output); **never emits a larger file** — on no gain it returns `.noGain` and writes
/// nothing; re-validates every delivered output before success. A gs exit 0 that produces no /
/// invalid output is a failure, never "already optimised".
///
/// Content routing is live: a document classified `.scanBilevel` is attempted through Rung 2
/// (binarise + CCITT G4, composed natively) and falls back to Rung 1 on any doubt; every other
/// classification goes straight to Rung 1. Rung 3 (MRC) is not built.
struct CompressEngine {
    /// Longest side, in pixels, any Rung-2 page render may reach — the memory guard against a
    /// hostile `/MediaBox`.
    static let maxBilevelPixels: CGFloat = 5000
    /// Effective resolution below which Rung 2 declines rather than shipping a degraded rebuild.
    static let minBilevelDPI: CGFloat = 150
    /// Most pages Rung 2 will attempt in one document.
    ///
    /// Unlike Rung 1, which streams through Ghostscript, Rung 2 holds every page's encoded payload
    /// until the whole document can be composed, and the composer builds the output in a single
    /// in-memory `Data`. Peak is therefore about twice the encoded document, multiplied by the
    /// queue's concurrency. `maxBilevelPixels` bounds one page's raster and nothing bounds the
    /// count, so a very long scan is the one shape that can still exhaust memory here. Beyond this
    /// the document goes to Rung 1, which has no such ceiling.
    static let maxBilevelPages = 1200
    /// Most pages Rung 3 will attempt in one document (≈ `maxBilevelPages` / 3, R13). MRC holds
    /// three encoded layers per page until the whole document composes and recomposes each page to
    /// verify it, so its per-page peak is several times Rung 2's — hence the tighter ceiling.
    /// Beyond this the document declines to the gs path, which streams and has no such limit.
    static let maxMRCPages = 400

    let runner: any GhostscriptRunning
    let service: PDFService
    let validator: OutputValidator

    init(runner: any GhostscriptRunning,
         service: PDFService = PDFService(),
         validator: OutputValidator = OutputValidator()) {
        self.runner = runner
        self.service = service
        self.validator = validator
    }

    func compress(_ input: URL,
                  preset: CompressPreset,
                  to output: URL,
                  alternateOutput: URL? = nil,
                  mrcReport: ((MRCDocumentReport) -> Void)? = nil,
                  progress: @escaping (Double) -> Void) async throws -> JobOutcome {
        // Task 4: both parameters are pass-through only — Rung 3 (Task 15) fills in the MRC
        // attempt behind this already-present signature. Existing behaviour is byte-identical.
        _ = alternateOutput
        _ = mrcReport
        let fm = FileManager.default
        let input = input.canonical
        let output = output.canonical
        guard input.path != output.path else { throw CompressError.sameInputOutput }

        // 1. Up-front open guard (on the original input — the parent app holds the TCC grant).
        let pageCount: Int
        switch try OpenGuard.inspect(input) {
        case .ok(let count): pageCount = count
        case .encrypted: throw CompressError.encrypted
        case .corrupt: throw CompressError.corrupt
        }

        let inputSize = Self.fileSize(input)
        let outputDir = output.deletingLastPathComponent().canonical

        // Rung 2 can process several pages — driving progress up — before declining on a LATER
        // page and falling through to Rung 1, which then starts its own progress back near 0.
        // The caller's progress bar must never regress, so every progress call in this function
        // goes through a monotonic (never-decreasing) filter rather than the raw callback.
        var progressHighWaterMark = 0.0
        func reportProgress(_ value: Double) {
            guard value > progressHighWaterMark else { return }
            progressHighWaterMark = value
            progress(value)
        }

        // 2. Stage all gs I/O through a private working dir under the system temp dir
        //    (`NSTemporaryDirectory`, under ~/Library — TCC-exempt). A seatbelt-sandboxed gs
        //    child cannot inherit the app's TCC grant, so it must never be handed a path in a
        //    TCC-protected folder (~/Documents, ~/Downloads, ~/Desktop) — that hangs on a TCC
        //    decision the non-interactive child can't answer. The parent app (which HAS the
        //    grant) copies the input in and, on success, the result back out. Always removed.
        let work = fm.temporaryDirectory
            .appendingPathComponent("Toolbox/\(UUID().uuidString)", isDirectory: true).canonical
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let workIn = work.appendingPathComponent("in.pdf")
        let workOut = work.appendingPathComponent("out.pdf")
        try fm.copyItem(at: input, to: workIn)

        // 3. Rung 2 first for scans that are visually two-tone. Ghostscript's mono settings only
        //    apply to images that are ALREADY 1-bit, so a greyscale scan that merely looks
        //    black-and-white is treated as a grey image and can come out LARGER — measured on a
        //    representative sample at roughly 29% growth. Binarising first and encoding CCITT G4
        //    is where the large saving is. Any failure, or a result that is not smaller and valid,
        //    falls through to Rung 1 — no document is ever left unhandled or worse off (R2-N1).
        var bilevelOutcome: Int?
        if (try? service.classify(input)) == .scanBilevel {
            do {
                bilevelOutcome = try await bilevelCompress(input, preset: preset, to: work,
                                                           progress: reportProgress)
            } catch let cancellation as CancellationError {
                // A cancelled Rung-2 attempt must not be swallowed into "decline, try Rung 1" —
                // that would burn a whole Ghostscript pass after the caller has already given up.
                throw cancellation
            } catch {
                bilevelOutcome = nil   // any other failure declines Rung 2; falls through to Rung 1
            }
        }
        if let bilevel = bilevelOutcome, bilevel < inputSize {
            let staged = work.appendingPathComponent("bilevel.pdf")
            if (try? validator.validate(input: input, output: staged, samplePages: 3)) == true {
                try Task.checkCancellation()
                let destTemp = outputDir.appendingPathComponent(".toolbox-\(UUID().uuidString).pdf").canonical
                var placed = false
                defer { if !placed { try? fm.removeItem(at: destTemp) } }
                try fm.copyItem(at: staged, to: destTemp)
                // Immediately before the rename, matching the Rung-1 path below. Checking only
                // before the copy leaves the copy itself — which for a large scan is the slow
                // part — as a window where a cancel is never observed and the file still ships.
                try Task.checkCancellation()
                try fm.moveItem(at: destTemp, to: output)
                placed = true
                reportProgress(1.0)
                return .compressed(before: inputSize, after: bilevel)
            }
        }

        // 4. Otherwise run gs sandboxed, scoped to the work dir only (Rung 1).
        let arguments = preset.gsArguments()
            + ["-sOutputFile=\(workOut.path)", "-c", preset.gsDistillerParams(), "-f", workIn.path]
        let result = try await runner.run(
            arguments: arguments,
            readPaths: [workIn],
            writePaths: [work],
            onProgress: { page in
                if pageCount > 0 { reportProgress(min(1.0, Double(page) / Double(pageCount))) }
            })
        // A cancel that landed while gs was running (or just as it finished) must produce nothing:
        // the work dir's `defer` discards the staged output and the job returns to `.queued`.
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw CompressError.ghostscriptFailed(Self.failureMessage(result))
        }

        // 4. A gs exit 0 that produced no output is a SILENT FAILURE, never "already optimised".
        let outputSize = Self.fileSize(workOut)
        guard outputSize > 0 else {
            throw CompressError.ghostscriptFailed("Ghostscript exited successfully but produced no output.")
        }

        // 5. Never emit a larger file — on no gain keep the original and write nothing. The
        //    ≥-input output must still be a valid PDF (opens, page count preserved): otherwise a
        //    silent gs corruption that happens to be ≥ the input would masquerade as `.noGain`.
        guard outputSize < inputSize else {
            guard let outDoc = PDFDocument(url: workOut), outDoc.pageCount == pageCount else {
                throw CompressError.ghostscriptFailed("Ghostscript produced an invalid output.")
            }
            return .noGain(bytes: inputSize)
        }

        // 6. Re-validate the smaller output before it is delivered.
        guard try validator.validate(input: workIn, output: workOut, samplePages: 3) else {
            throw CompressError.validationFailed
        }

        // 7. Copy the result onto the DESTINATION volume, then atomically rename into place
        //    (same volume → rename can't cross-device-fail; unique name → never overwrites).
        let destTemp = outputDir.appendingPathComponent(".toolbox-\(UUID().uuidString).pdf").canonical
        var placed = false
        defer { if !placed { try? fm.removeItem(at: destTemp) } }
        try fm.copyItem(at: workOut, to: destTemp)
        // Last gate before the file becomes visible: a cancel that lands during validation still
        // leaves no delivered output (`placed` stays false, so the `defer` removes the temp).
        try Task.checkCancellation()
        try fm.moveItem(at: destTemp, to: output)
        placed = true

        reportProgress(1.0)
        return .compressed(before: inputSize, after: outputSize)
    }

    /// What the user is shown — and what the job list retains — when gs fails.
    ///
    /// Both gs's stdout AND stderr are attacker-influenced text (gs quotes fragments of the
    /// input in its messages on either stream — measured: a bogus `-sDEVICE` puts its whole
    /// diagnosis on stdout with nothing on stderr at all), so the message combines the tail of
    /// both: the earlier lines of a long gs failure are repetition, the diagnosis is at the end.
    /// The runner already caps what it captures on each stream; this caps what is displayed.
    private static func failureMessage(_ result: ProcessResult) -> String {
        func tail(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(2)
                .joined(separator: " ")
        }
        let combined = [tail(result.stderr), tail(result.stdout)]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        guard !combined.isEmpty else { return "exit \(result.exitCode)" }
        return combined.count > 300 ? String(combined.prefix(300)) + "…" : combined
    }

    /// Rung 2: binarise every page and re-encode it as CCITT G4. Returns the output size, or nil
    /// when the document is not a good fit — in which case the caller falls back to Rung 1.
    ///
    /// Binarisation is irreversible in appearance terms, so a page that is not genuinely
    /// near-two-tone aborts the whole attempt: a wrongly-binarised photograph is a far worse
    /// outcome than a missed saving.
    private func bilevelCompress(_ input: URL,
                                 preset: CompressPreset,
                                 to work: URL,
                                 progress: @escaping (Double) -> Void) async throws -> Int? {
        guard let document = PDFDocument(url: input), document.pageCount > 0,
              document.pageCount <= Self.maxBilevelPages else { return nil }

        // Rung 2 repaints each page as a bitmap, so everything that is not painted pixels is gone:
        // a searchable text layer — including one this app's own OCR added — annotations, form
        // fields, bookmarks. `classify` samples only five pages and calls a page "text" only above
        // 40 characters, so a document with a sparse cover page or short pages can be routed here
        // while still carrying content worth keeping. The check therefore has to be per page and
        // over EVERY page, not a sample, and it must be here rather than in the classifier.
        guard document.outlineRoot == nil else { return nil }

        var pages: [BilevelPDFComposer.Page] = []
        pages.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { return nil }
            guard page.annotations.isEmpty else { return nil }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty else { return nil }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }

            // Render at the preset's bilevel DPI, bounded so a hostile /MediaBox cannot blow memory.
            let scale = CGFloat(preset.bilevelDPI) / 72.0
            let longestSide = max(box.width, box.height)
            let maxDimension = min(longestSide * scale, Self.maxBilevelPixels)

            // That cap is a memory guard and must never double as a silent quality decision. On a
            // large-format page it becomes one: an A0 sheet at the highest preset clamps to about
            // 107 dpi, losing hairlines and small print — and the result is still smaller, so it
            // would ship as a success. Below the floor, decline and let Rung 1 handle it.
            guard maxDimension / longestSide * 72.0 >= Self.minBilevelDPI else { return nil }

            let rendered = try service.render(page, maxDimension: maxDimension)

            // `binarise` applies the near-bilevel gate itself and returns nil when the page fails
            // it, so calling `isNearBilevel` first would only repeat the same full-bitmap scan.
            guard let bitmap = BilevelScan.binarise(rendered),
                  let binarised = bitmap.cgImage,
                  let encoded = CCITTEncoder.encode(binarised) else { return nil }

            pages.append(.init(image: encoded, size: box.size, rotation: page.rotation))
            progress(Double(index + 1) / Double(document.pageCount))
        }

        let data = try BilevelPDFComposer.compose(pages: pages)
        let staged = work.appendingPathComponent("bilevel.pdf")
        try data.write(to: staged, options: .atomic)
        return data.count
    }

    /// Rung 3: per-page MRC with own-render JPEG fallback (spec §5). Returns the composed hybrid's
    /// byte count and per-page report, or nil to decline the whole document. Per-page failures decline
    /// to fallback content internally; a composition or write failure DOES propagate out of this method —
    /// the routing gate converts it to a whole-document decline at the call site (same catch shape as
    /// Rung 2's `bilevelCompress` caller). Only `CancellationError` may pass through that call-site catch.
    ///
    /// Reached directly by tests until the routing/D7 gate (Task 15) wires it behind `compress`; it
    /// is `internal` rather than `private` for exactly that reason. `forceEligible` and
    /// `verifierOverride` are test-only seams (both default off): the former pushes a page past the
    /// classifier envelope, the latter rewrites a page's verifier score so the verify→fallback swap
    /// (spec §9) can be exercised deterministically. Neither has a production caller.
    func mrcCompress(_ input: URL,
                     preset: CompressPreset,
                     to work: URL,
                     forceEligible: Bool = false,
                     verifierOverride: ((MRCVerifier.Score) -> MRCVerifier.Score)? = nil,
                     progress: @escaping (Double) -> Void) async throws
                     -> (url: URL, bytes: Int, report: MRCDocumentReport)? {
        guard let document = PDFDocument(url: input), document.pageCount > 0,
              document.pageCount <= Self.maxMRCPages,
              // The composed output is a fresh document: bookmarks cannot be carried, so a
              // bookmarked scan must take the gs path or it silently loses its outline — the same
              // guard, for the same reason, as `bilevelCompress`.
              document.outlineRoot == nil else { return nil }

        // R2 structural sweep first — cheap, and one complex page kills the whole attempt before
        // any rasterising, because the fallback path rasterises and rasterising text is destruction.
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  MRCClassifier.structure(of: page) == .simpleSingleImage else { return nil }
        }

        var pages: [MRCComposer.Page] = []
        var verdicts: [MRCPageVerdict] = []
        var anyMRC = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { return nil }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }

            // Rendered bounded exactly like Rung 2 (R13): preset DPI, clamped to maxBilevelPixels.
            let scale = CGFloat(preset.bilevelDPI) / 72.0
            let maxDimension = min(max(box.width, box.height) * scale, Self.maxBilevelPixels)

            let content: MRCComposer.PageContent
            let verdict: MRCPageVerdict
            do {
                (content, verdict) = try mrcPage(page, box: box, maxDimension: maxDimension,
                                                 preset: preset, forceEligible: forceEligible,
                                                 verifierOverride: verifierOverride)
            } catch is MRCDecline {
                return nil                              // a page with no fallback → decline the document
            }
            pages.append(MRCComposer.Page(content: content, size: box.size, rotation: page.rotation))
            verdicts.append(verdict)
            if case .mrcEncoded = verdict { anyMRC = true }
            progress(Double(index + 1) / Double(document.pageCount))
        }   // per-page rasters go out of scope here — only the encoded payloads are retained (R13)

        guard anyMRC else { return nil }                // R7: no MRC page → nothing to gain over gs
        let data = try MRCComposer.compose(pages: pages)
        let out = work.appendingPathComponent("mrc.pdf")
        try data.write(to: out, options: .atomic)
        return (out, data.count, MRCDocumentReport(verdicts: verdicts))
    }

    /// One page: classify → segment → encode → verify (D6), else the fallback JPEG (R5). Returns
    /// the composed content and the verdict recorded for it. Throws only `MRCDecline`, and only when
    /// even the full-page render fails so no fallback is possible.
    private func mrcPage(_ page: PDFPage, box: CGRect, maxDimension: CGFloat,
                         preset: CompressPreset, forceEligible: Bool,
                         verifierOverride: ((MRCVerifier.Score) -> MRCVerifier.Score)?) throws
                         -> (MRCComposer.PageContent, MRCPageVerdict) {
        // The full render feeds both the MRC split and the fallback; if it fails there is nothing
        // to ship for this page, so the whole document declines.
        guard let full = try? service.render(page, maxDimension: maxDimension) else { throw MRCDecline() }

        // One tiny classifier render (R14) yields the eligibility signals — also recorded on an
        // MRC verdict as the debugging trail (spec §6).
        let classifierDimension = MRCClassifier.renderDimension(for: page)
        let features = (try? service.render(page, maxDimension: classifierDimension))
            .flatMap(MRCClassifier.features(of:))

        if !forceEligible {
            guard let features else {
                return (try fallbackJPEG(page, box: box, preset: preset), .fallback(.renderFailed))
            }
            if let reason = MRCClassifier.verdict(features: features) {
                return (try fallbackJPEG(page, box: box, preset: preset), .fallback(reason))
            }
        }

        // Eligible (or forced). A missing feature record only arises on the forced path, where the
        // classifier render was skipped or failed; the verdict still needs one, so default to zeros.
        let recorded = features ?? MRCPageFeatures(inkCoverage: 0, meanComponentSize: 0,
                                                   componentCount: 0, colourCoverage: 0)

        guard let segmented = MRCSegmenter.segment(full) else {
            return (try fallbackJPEG(page, box: box, preset: preset), .fallback(.segmentationFailed))
        }
        guard let encoded = MRCPageEncoder.encode(segmented, preset: preset),
              let candidate = MRCPageEncoder.recompose(encoded) else {
            return (try fallbackJPEG(page, box: box, preset: preset), .fallback(.encodeFailed))
        }

        // Verify the recomposed hybrid against the original over the ink region (D6) — the smear
        // gate. A dimension mismatch (never expected: candidate, input and mask share the render
        // size) has no meaningful score, so it is treated as a rejection, not a silent pass.
        var score = MRCVerifier.score(candidate: candidate, input: full, mask: segmented.mask)
            ?? MRCVerifier.Score(normalisedError: .infinity, pass: false)
        if let verifierOverride { score = verifierOverride(score) }
        guard score.pass else {
            return (try fallbackJPEG(page, box: box, preset: preset),
                    .fallback(.verifierRejected(score: score.normalisedError)))
        }

        let content = MRCComposer.PageContent.mrc(background: encoded.background,
                                                  foreground: encoded.foreground, mask: encoded.mask)
        return (content, .mrcEncoded(recorded))
    }

    /// The R5 fallback: re-render the page at the preset's contone DPI (below the MRC render's mono
    /// DPI, so genuinely smaller) and JPEG it at the background layer's quality. A render failure
    /// here leaves the page with nothing to ship, so it declines the whole document.
    private func fallbackJPEG(_ page: PDFPage, box: CGRect,
                              preset: CompressPreset) throws -> MRCComposer.PageContent {
        let scale = CGFloat(preset.imageDPI) / 72.0
        let maxDimension = min(max(box.width, box.height) * scale, Self.maxBilevelPixels)
        guard let image = try? service.render(page, maxDimension: maxDimension),
              let jpeg = MRCPageEncoder.encodeJPEG(image, quality: MRCPageEncoder.layerQualities(for: preset).bg)
        else { throw MRCDecline() }
        return .jpeg(jpeg)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
