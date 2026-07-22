// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
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
/// A content router seam is present (all types route to Rung-1 gs in v1); Rungs 2/3 slot in later.
struct CompressEngine {
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

        // 2. Stage all gs I/O through a private working dir under the system temp dir
        //    (`NSTemporaryDirectory`, under ~/Library — TCC-exempt). A seatbelt-sandboxed gs
        //    child cannot inherit the app's TCC grant, so it must never be handed a path in a
        //    TCC-protected folder (~/Documents, ~/Downloads, ~/Desktop) — that hangs on a TCC
        //    decision the non-interactive child can't answer. The parent app (which HAS the
        //    grant) copies the input in and, on success, the result back out. Always removed.
        let work = fm.temporaryDirectory
            .appendingPathComponent("PDFToolbox/\(UUID().uuidString)", isDirectory: true).canonical
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let workIn = work.appendingPathComponent("in.pdf")
        let workOut = work.appendingPathComponent("out.pdf")
        try fm.copyItem(at: input, to: workIn)

        // 3. Run gs sandboxed, scoped to the work dir only (all content types → Rung-1 in v1).
        let arguments = preset.gsArguments() + ["-sOutputFile=\(workOut.path)", workIn.path]
        let result = try await runner.run(
            arguments: arguments,
            readPaths: [workIn],
            writePaths: [work],
            onProgress: { page in
                if pageCount > 0 { progress(min(1.0, Double(page) / Double(pageCount))) }
            })
        guard result.exitCode == 0 else {
            throw CompressError.ghostscriptFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
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
        let destTemp = outputDir.appendingPathComponent(".pdftoolbox-\(UUID().uuidString).pdf").canonical
        var placed = false
        defer { if !placed { try? fm.removeItem(at: destTemp) } }
        try fm.copyItem(at: workOut, to: destTemp)
        try fm.moveItem(at: destTemp, to: output)
        placed = true

        progress(1.0)
        return .compressed(before: inputSize, after: outputSize)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
