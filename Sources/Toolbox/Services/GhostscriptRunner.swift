// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
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
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "The bundled Ghostscript binary could not be found."
        case .launchFailed(let msg): return "Ghostscript failed to launch: \(msg)"
        case .timedOut(let seconds):
            return "Ghostscript timed out after \(Int(seconds)) seconds and was terminated."
        }
    }
}

/// The seam `CompressEngine` depends on, so a test can substitute a double that reproduces gs
/// outcomes the real binary can't be forced to produce deterministically — chiefly an
/// exit-0-but-no-output *silent* failure. Production always uses `GhostscriptRunner`.
protocol GhostscriptRunning {
    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult
}

/// Shared, lock-guarded handle on the launched gs child.
///
/// Task cancellation arrives on a different thread from the one parked in `waitUntilExit()`,
/// so the two need a rendezvous: the cancellation handler terminates whatever child is running
/// (or, if none has launched yet, records the cancellation so the launcher terminates it the
/// moment it appears). `Process.terminate()` raises if the process was never launched, which is
/// why the child is only adopted *after* `run()` succeeds.
private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Publish the just-launched child; terminates it at once if cancellation already arrived.
    func adopt(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled, process.isRunning { GhostscriptRunner.terminateEscalating(process) }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { GhostscriptRunner.terminateEscalating(process) }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
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
    ///
    /// `async` and **non-blocking for the caller**: the blocking process wait runs on a global
    /// dispatch thread and the caller *suspends* (bridged via a continuation), so many
    /// concurrent compressions under `ToolQueue` never starve the Swift cooperative pool.
    ///
    /// **Cancellation terminates the child.** Cancelling the calling task signals the running gs
    /// process, and the call then throws `CancellationError` — so a cancelled job stops burning a
    /// core immediately and its caller can discard the output before it is ever placed.
    /// - Parameters:
    ///   - readPaths: extra readable paths (typically the input PDF).
    ///   - writePaths: writable paths (typically the output directory).
    ///   - onProgress: called with each gs page number as gs emits it — once per marker, strictly
    ///     increasing, **on the runner's background thread**, never the caller's (the ticks arrive
    ///     while the calling task is still suspended, so the callback must tolerate that thread).
    ///     Best-effort in a concrete sense: only gs's *PDF* interpreter emits `Page N` markers
    ///     (measured — a PostScript input emits none), so a run can legitimately report nothing.
    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)? = nil) async throws -> ProcessResult {
        let control = RunControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try self.runBlocking(arguments: arguments, readPaths: readPaths,
                                                          writePaths: writePaths, onProgress: onProgress,
                                                          control: control)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// How much of gs's stdout/stderr is kept, each. Enough for any real diagnostic; small enough
    /// that a hostile input cannot make the app retain megabytes of either.
    private static let outputTailLimit = 4096

    /// Drain `handle` to EOF, keeping at most `limit` trailing bytes and — when `onPage` is given —
    /// reporting gs's `Page N` markers *as they arrive*.
    ///
    /// The pipe must always be drained to EOF or a chatty child blocks on a full pipe buffer — but
    /// nothing says the bytes must be *kept*. Both of gs's streams are attacker-influenced (a
    /// malformed PDF can provoke a warning per object, and gs echoes fragments of the input in its
    /// messages on either stdout or stderr — measured: a bogus `-sDEVICE` puts its whole diagnosis
    /// on stdout with nothing on stderr) and both end up retained in the job list and rendered in
    /// the UI, so only the tail of each is kept: a failing gs puts its fatal diagnostic last.
    ///
    /// Progress therefore *has* to be parsed here rather than from the returned tail: gs
    /// line-flushes `Page N` to the pipe as each page is emitted (measured), while the tail keeps
    /// only the last `limit` bytes — so a run whose chatter outgrows the tail has already lost its
    /// early markers by the time it exits. Markers are reported monotonically (a repeated or
    /// out-of-order number is dropped), so a caller's progress bar can never move backwards.
    static func drainTail(_ handle: FileHandle, limit: Int, onPage: ((Int) -> Void)? = nil) -> Data {
        var tail = Data()
        var line = Data()                                               // bytes since the last newline
        var lastPage = 0
        func report(_ candidate: Data) {
            guard let page = Self.pageMarker(candidate), page > lastPage else { return }
            lastPage = page
            onPage?(page)
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }                                  // EOF
            tail.append(chunk)
            if tail.count > limit { tail.removeFirst(tail.count - limit) }
            guard onPage != nil else { continue }
            for byte in chunk {
                if byte == 0x0A || byte == 0x0D {                       // LF or CR ends a line
                    report(line)
                    line.removeAll(keepingCapacity: true)
                } else if line.count < Self.maxProgressLineBytes {
                    line.append(byte)
                }
            }
        }
        if onPage != nil { report(line) }                               // an unterminated last line
        return tail
    }

    /// A `Page N` marker is the only line the progress parse reads, so no more of a line than that
    /// is ever buffered — a hostile input that provokes megabyte-long gs diagnostics with no newline
    /// cannot make the parser retain them, and clamping the *end* of an over-long line leaves the
    /// prefix (the only load-bearing part) intact.
    private static let maxProgressLineBytes = 64
    private static let pageMarkerPrefix = Array("Page ".utf8)

    /// gs's per-page marker (`Page 12`) → its page number; nil for every other line.
    private static func pageMarker(_ line: Data) -> Int? {
        guard line.starts(with: pageMarkerPrefix) else { return nil }
        // Non-failable decode: the bytes are attacker-influenced, and a nil here would silently
        // drop a legitimate marker (§4.6).
        let number = String(decoding: line.dropFirst(pageMarkerPrefix.count), as: UTF8.self)
        return Int(number.trimmingCharacters(in: .whitespaces))
    }

    /// SIGTERM, then SIGKILL if the child is still alive `grace` seconds later. Both the
    /// wall-clock watchdog and cancellation go through here, so neither is merely cooperative: a
    /// gs that installs a SIGTERM handler or blocks uninterruptibly would otherwise park the
    /// waiting thread forever — the continuation never resumes, the queue slot is never freed and
    /// the scratch directory is never cleaned.
    ///
    /// The escalation needs no bookkeeping: `terminate()` is documented as a no-op on a child that
    /// has already finished, and the `SIGKILL` is gated on `isRunning`.
    ///
    /// That gate is check-then-act, not a guarantee, and the comment that used to claim otherwise
    /// was wrong: retaining the `Process` object is not a mechanism — Foundation reaps the child on
    /// its own dispatch source, independently of the object's lifetime — so the child can exit and
    /// be reaped between `isRunning` and `kill(2)`, and the pid could in principle be recycled
    /// inside that window. The window is accepted rather than closed: it opens only for a child
    /// still alive `grace` seconds after SIGTERM, and dropping the `SIGKILL` is not on the table —
    /// it is the only thing that stops a gs which ignores SIGTERM from parking the waiting thread
    /// forever (pinned by `testTerminateEscalatesToSIGKILL`).
    static func terminateEscalating(_ process: Process, grace: TimeInterval = 5) {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func runBlocking(arguments: [String],
                             readPaths: [URL],
                             writePaths: [URL],
                             onProgress: ((Int) -> Void)?,
                             control: RunControl) throws -> ProcessResult {
        let fm = FileManager.default

        // gs's pdfwrite device writes scratch temp files to $TMPDIR; under (deny default) the
        // system temp dir is out of scope, so give gs a private, in-scope scratch directory.
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("toolbox-gs-\(UUID().uuidString)", isDirectory: true)
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

        do {
            try process.run()
        } catch {
            throw GhostscriptError.launchFailed(error.localizedDescription)
        }
        // Hand the child to the cancellation handler only now: `terminate()` raises on a process
        // that was never launched, and a cancel that arrived during launch is honoured here.
        control.adopt(process)

        // Wall-clock cap without a busy-wait: a watchdog terminates a runaway/hung gs; otherwise
        // this (global-queue) thread blocks until gs exits. When the watchdog fires it records the
        // fact under a lock so the timeout can be surfaced as a *dedicated* error (the UI shows
        // "timed out", not a bare non-zero exit) and the batch continues. It is armed BEFORE the
        // drain below and must stay that way: the drain parks in `availableData` until gs closes
        // its stdout, so on a silent hang the watchdog is the only thing that ever ends the wait.
        let timeoutLock = NSLock()
        var didTimeout = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timeoutLock.lock(); didTimeout = true; timeoutLock.unlock()
                Self.terminateEscalating(process)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + wallClockTimeout, execute: watchdog)

        // Both pipes are drained to EOF concurrently with the child — the deadlock-free pattern;
        // large gs output can exceed the 64 KB pipe buffer, so draining after the wait would hang.
        // (Do NOT mix a readabilityHandler with readDataToEndOfFile: the handler's dispatch source
        // consumes EOF and the later read then blocks forever.) Only *one* of the two needs a
        // thread of its own, though: stderr goes to the shared global queue — never a freshly
        // created private concurrent queue, each of which costs its own thread resources — while
        // stdout is drained on this thread, so a gs job parks two threads rather than three. That
        // also keeps progress single-threaded: the ticks are delivered on the very thread that goes
        // on to resume the caller's continuation. Both drains start only after a successful launch,
        // so a `launchFailed` throw abandons neither.
        var errData = Data()
        let ioGroup = DispatchGroup()
        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = Self.drainTail(errPipe.fileHandleForReading, limit: Self.outputTailLimit)
            ioGroup.leave()
        }
        let outData = Self.drainTail(outPipe.fileHandleForReading, limit: Self.outputTailLimit,
                                     onPage: onProgress)
        process.waitUntilExit()
        watchdog.cancel()
        ioGroup.wait()

        // A cancelled run is a cancellation, never a timeout or a result: the child was signalled,
        // so whatever it left behind is partial and the caller must place none of it.
        if control.isCancelled { throw CancellationError() }

        // Distinguish a genuine timeout from a job that finished on the wire: a process that
        // exited cleanly (status 0) at the deadline is a success, never a timeout — so require a
        // non-zero termination (a terminated gs carries SIGTERM ⇒ non-zero) before throwing.
        timeoutLock.lock(); let timedOut = didTimeout; timeoutLock.unlock()
        if timedOut && process.terminationStatus != 0 {
            throw GhostscriptError.timedOut(seconds: wallClockTimeout)
        }

        // Decoded with UTF-8 *repair*, never `String(data:encoding:)`: that initialiser is failable
        // and returns nil on the first ill-formed byte, so a tail cut mid-sequence — or a fragment
        // of the untrusted input that gs echoed into its diagnostic — would replace the job's whole
        // failure reason with an empty string, on exactly the path that most needs it (§4.6).
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

extension GhostscriptRunner: GhostscriptRunning {}
