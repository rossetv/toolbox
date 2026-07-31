// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Why a leg could not run, or why a file cannot be worked on at all. This is meta-line
/// vocabulary — the problem ROW's own tint and copy are decided by the view, never from here.
enum RowProblem: Equatable {
    /// The PDF needs a password to open.
    case locked
    /// The file has moved or been deleted since it was added.
    case missing
    /// The file could not be opened as a PDF.
    case unreadable
    /// Ghostscript or output validation failed on a readable file — the compress-specific failure
    /// the OCR rescue is built on (spec §6.5): the row is degraded, never "failed".
    case compressFailed

    /// The Problems screen's copy for this condition (spec §7/§6.6) — the one table both add-time
    /// inspection (`RowInspection.metaLine`) and the run-time second net (`QueueRowsView
    /// .describeFailed`) read, so a file caught locked/missing/unreadable at either moment reads
    /// identically. `compressFailed` has no row copy here: it is a RUN outcome (the OCR rescue),
    /// never a problem row.
    var problemCopy: String {
        switch self {
        case .locked: return "Needs a password to open"
        case .missing: return "Moved or renamed since you added it"
        case .unreadable: return "This file can't be read as a PDF"
        case .compressFailed: return ""
        }
    }

    /// Maps `OpenGuard`'s run-time "second net" (spec §6.6) back onto the same problem add-time
    /// inspection would have raised for the identical condition — the run-time catch only ever
    /// sees `OpenGuardError`/`CompressError`/`OCRError`'s fixed, known strings, so this is a closed
    /// set, not free-text sniffing. `nil` for a genuine run-time-only failure (Ghostscript,
    /// validation) that has no add-time equivalent and keeps its own message.
    static func fromRunTimeFailure(_ message: String) -> RowProblem? {
        switch message {
        case "The PDF is password-protected.": return .locked
        case "The file could not be found.": return .missing
        case "The PDF is damaged and cannot be read.": return .unreadable
        default: return nil
        }
    }
}

/// The second variant a job retained on disk, described for the row that owns it. It exists
/// whenever a second valid variant was kept — **regardless of which variant won the size gate**
/// (spec §5's R7 reversal): its presence, not the winner, is what triggers the consent sheet and
/// the versions capsule.
struct RetainedVariant: Equatable {
    /// Which engine leg produced the parked file.
    let kind: EngineVariant
    /// Its size on disk. Mutable because the commit step re-stats every variant the OCR leg
    /// appended a text layer to — a pre-append number on a card would be the wrong number.
    var bytes: Int
    /// Whether this variant carries an extractable text layer. Set from the append's real result,
    /// never assumed: a variant that could not carry the layer is labelled honestly (spec §6.4).
    var searchable: Bool
}

/// What the compress leg did to a file. Absent from a `RowOutcome` when the verb was off.
enum CompressOutcome: Equatable {
    /// Compression succeeded: `before` bytes → `after` bytes (`after` < `before`). The sizes are
    /// the COMPRESS artefact's; an OCR append afterwards can still grow the delivered file.
    case compressed(before: Int, after: Int)
    /// Compression produced nothing smaller — the original is kept, no compress artefact written.
    case noGain(bytes: Int)
    /// The leg was skipped by a problem while the other leg ran (spec §6.3) — the rescue's state.
    case skipped(problem: RowProblem)
}

/// What the OCR leg did to a file. Absent from a `RowOutcome` when the verb was off; a run that
/// was stopped between the legs reports `.cancelled`, never absence.
enum OCROutcome: Equatable {
    /// A text layer was added to `pages` pages; `skipped` pages already had one.
    case added(pages: Int, skipped: Int)
    /// Every page already had extractable text — nothing to recognise.
    case alreadySearchable
    /// Recognition completed and produced zero usable text runs across the pages that lacked a
    /// layer (spec §6.3). No confidence signal exists — this is the engine's own zero-runs fact.
    case tooFaint
    /// The batch was cancelled between the legs: the compress delivery was atomic and is banked,
    /// so the row keeps its file and says so honestly (spec §6.5).
    case cancelled
    /// Recognition failed, with the user-facing message.
    case failed(String)
}

/// The compound per-file result of the queue's single pass (spec §6.3). One file can be both
/// compressed and made searchable, so the two legs are reported side by side rather than as
/// mutually exclusive cases.
struct RowOutcome: Equatable {
    /// The input's size — what every badge, pill and banner total is measured against.
    var originalBytes: Int
    /// The delivered file's size. The engine sets it to the COMPRESS artefact's size; the queue's
    /// commit step re-stats the delivered file after the OCR leg and overwrites it, so `grew` is
    /// only meaningful once the row has been committed.
    var finalBytes: Int
    /// nil when the Compress verb was off for this row.
    var compress: CompressOutcome?
    /// nil when the OCR verb was off for this row — a cancelled-between-legs read is `.cancelled`.
    var ocr: OCROutcome?
    /// Which variant won and shipped. Read by the estimate calibration, the switch direction and
    /// the switch re-run's tail; never a substitute for `runnerUp` when asking whether a second
    /// variant was retained.
    var shippedVariant: EngineVariant?
    /// Non-nil when a second variant was retained on disk.
    var runnerUp: RetainedVariant?

    /// A combined pass can net larger: modest compression plus a big text layer adds content the
    /// user asked for. Derived, so it can never disagree with the sizes the row shows.
    var grew: Bool { finalBytes > originalBytes }

    /// Rows that delivered a file with an honest caveat — a rescued row whose compress leg failed,
    /// a read that found nothing usable, a read cancelled between the legs, and a read that failed
    /// on an already-delivered file. All of these warn; none of them is a FAILED row, because the
    /// Problems footer's promise ("Files that failed were not touched at all") must stay true.
    /// A variant that could not carry the text layer is shown through its own label (spec §6.4),
    /// never through the row's state.
    var isDegraded: Bool {
        if case .skipped = compress { return true }
        if ocr == .tooFaint || ocr == .cancelled { return true }
        if case .failed = ocr { return true }
        return false
    }
}

/// A job's lifecycle state. `ToolQueue` owns the `.queued`/`.running`/`.done`/`.failed`
/// transitions; `.analysing` is a view-model-only overlay — `ToolQueue` never produces it.
/// `QueueViewModel.publishJobs()` layers it onto a job that is still `.queued` in the queue
/// while a size estimate is in flight.
enum JobState: Equatable {
    case queued
    case analysing
    case running(Double)          // 0...1 fraction; use indeterminate UI when unknown
    case done(RowOutcome)
    case failed(String)           // user-facing failure message
}
