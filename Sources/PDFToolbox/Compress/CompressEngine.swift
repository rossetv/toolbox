// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

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
/// Safety contract (spec §5.4): inspects the input first (encrypted/corrupt rejected); writes
/// to a temp file **in the output directory** then **atomically renames** (never overwrites the
/// input; a failure/cancel leaves no partial output); **never emits a larger file** — on no gain
/// it returns `.noGain` and writes nothing; re-validates every output before success.
///
/// A content router seam is present (all types route to Rung-1 gs in v1); Rungs 2/3 slot in later.
struct CompressEngine {
    let runner: GhostscriptRunner
    let service: PDFService
    let validator: OutputValidator

    init(runner: GhostscriptRunner,
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
        let input = input.canonical
        let output = output.canonical
        guard input.path != output.path else { throw CompressError.sameInputOutput }

        // 1. Up-front open guard.
        let pageCount: Int
        switch try OpenGuard.inspect(input) {
        case .ok(let count): pageCount = count
        case .encrypted: throw CompressError.encrypted
        case .corrupt: throw CompressError.corrupt
        }

        let inputSize = Self.fileSize(input)
        let outputDir = output.deletingLastPathComponent().canonical

        // 2. Temp file in the OUTPUT directory (same volume → atomic rename can't cross-device
        //    fail). Removed on every exit unless it was renamed into place.
        let tempURL = outputDir.appendingPathComponent(".pdftoolbox-\(UUID().uuidString).pdf").canonical
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: tempURL) } }

        // 3. Run gs (all types → Rung-1 in v1).
        let arguments = preset.gsArguments() + ["-sOutputFile=\(tempURL.path)", input.path]
        let result = try await runner.run(
            arguments: arguments,
            readPaths: [input],
            writePaths: [outputDir],
            onProgress: { page in
                if pageCount > 0 { progress(min(1.0, Double(page) / Double(pageCount))) }
            })
        guard result.exitCode == 0 else {
            throw CompressError.ghostscriptFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }

        // 4. Never emit a larger file — on no gain, keep the original and write nothing.
        let outputSize = Self.fileSize(tempURL)
        guard outputSize > 0, outputSize < inputSize else {
            return .noGain(bytes: inputSize)
        }

        // 5. Re-validate before success.
        guard try validator.validate(input: input, output: tempURL, samplePages: 3) else {
            throw CompressError.validationFailed
        }

        // 6. Atomic move into place (unique name via FileNaming → no overwrite).
        try FileManager.default.moveItem(at: tempURL, to: output)
        renamed = true
        progress(1.0)
        return .compressed(before: inputSize, after: outputSize)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
