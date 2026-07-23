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
                  progress: @escaping (Double) -> Void) async throws -> JobOutcome {
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
        let arguments = preset.gsArguments() + ["-sOutputFile=\(workOut.path)", workIn.path]
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
        guard let document = PDFDocument(url: input), document.pageCount > 0 else { return nil }

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

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
