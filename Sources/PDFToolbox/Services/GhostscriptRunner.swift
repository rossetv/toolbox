// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum GhostscriptError: Error, LocalizedError {
    case binaryNotFound
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "The bundled Ghostscript binary could not be found."
        case .launchFailed(let msg): return "Ghostscript failed to launch: \(msg)"
        }
    }
}

/// Runs the bundled Ghostscript **only ever** inside a seatbelt sandbox (never a bare
/// `Process`). Locates gs, wraps the call in `sandbox-exec -p <profile>` with `-dSAFER`,
/// gives gs a private in-scope scratch directory (via `TMPDIR`) that gs's `pdfwrite`
/// device needs, enforces a wall-clock cap, and best-effort parses page markers for
/// progress. The gs path is canonicalised once and used identically as the exec target
/// and the profile's `process-exec` literal (a symlink mismatch → `execvp Operation not
/// permitted`).
struct GhostscriptRunner {
    /// Canonical path to the bundled gs binary.
    let gsURL: URL

    /// Wall-clock cap per invocation; a runaway/hung gs is terminated.
    let wallClockTimeout: TimeInterval

    /// Production: locate gs inside the app bundle (`Contents/Resources/ghostscript/bin/gs`).
    init(wallClockTimeout: TimeInterval = 300) throws {
        guard let url = Bundle.main.url(forResource: "gs", withExtension: nil, subdirectory: "ghostscript/bin") else {
            throw GhostscriptError.binaryNotFound
        }
        self.gsURL = url.canonical
        self.wallClockTimeout = wallClockTimeout
    }

    /// Test/DI seam: an explicit gs path. NB tests use the bundled gs via `Bundle.main`
    /// (`init()`), not a repo path — a gs binary under a TCC-protected location such as
    /// `~/Documents` stalls a non-interactive process's `open()` on a TCC decision.
    init(gsURL: URL, wallClockTimeout: TimeInterval = 300) throws {
        let resolved = gsURL.canonical
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw GhostscriptError.binaryNotFound
        }
        self.gsURL = resolved
        self.wallClockTimeout = wallClockTimeout
    }

    /// Run gs with `arguments` (device/settings/output/input — the caller must pass canonical
    /// paths, matching `readPaths`/`writePaths`). `-dSAFER -dBATCH -dNOPAUSE` are always prepended.
    /// - Parameters:
    ///   - readPaths: extra readable paths (typically the input PDF).
    ///   - writePaths: writable paths (typically the output directory).
    ///   - onProgress: called with the latest gs page number as pages are emitted (best-effort).
    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)? = nil) throws -> ProcessResult {
        let fm = FileManager.default

        // gs's pdfwrite device writes scratch temp files to $TMPDIR; under (deny default) the
        // system temp dir is out of scope, so give gs a private, in-scope scratch directory.
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("pdftoolbox-gs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let scratchDir = scratch.canonical
        defer { try? fm.removeItem(at: scratchDir) }

        let profile = SeatbeltProfile.profile(
            gsPath: gsURL,
            readPaths: readPaths + [scratchDir],
            writePaths: writePaths + [scratchDir])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, gsURL.path, "-dSAFER", "-dBATCH", "-dNOPAUSE"] + arguments
        // Minimal environment: gs needs nothing but a writable TMPDIR (spike-verified). Not
        // inheriting the parent environment keeps the sandboxed child clean.
        process.environment = ["TMPDIR": scratchDir.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes to EOF on background threads — the deadlock-free pattern. (Do NOT
        // mix a readabilityHandler with readDataToEndOfFile: the handler's dispatch source
        // consumes EOF and the later read then blocks forever.) Large gs output can exceed the
        // 64 KB pipe buffer, so draining must run concurrently with the process, not after.
        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.pdftoolbox.gs.io", attributes: .concurrent)
        ioGroup.enter()
        ioQueue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave() }
        ioGroup.enter()
        ioQueue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave() }

        do {
            try process.run()
        } catch {
            throw GhostscriptError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(wallClockTimeout)
        while process.isRunning {
            if Date() >= deadline { process.terminate() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        ioGroup.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        // Best-effort progress: report the highest "Page N" gs emitted (coarse but real;
        // per spec [m10] indeterminate is acceptable when no marker is parseable).
        if let onProgress {
            var lastPage = 0
            for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                if line.hasPrefix("Page "),
                   let n = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)), n > lastPage {
                    lastPage = n
                }
            }
            if lastPage > 0 { onProgress(lastPage) }
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
