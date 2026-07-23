// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The tool-agnostic terminal result of a job, shared by both Compress and OCR.
enum JobOutcome: Equatable {
    /// Compression succeeded: input `before` bytes → output `after` bytes (`after` < `before`).
    case compressed(before: Int, after: Int)
    /// Compression produced nothing smaller — the original is kept, no file written.
    case noGain(bytes: Int)
    /// OCR added a searchable text layer to `pages` pages; `skipped` already had text.
    case ocrAdded(pages: Int, skipped: Int)
    /// Every page already had extractable text — nothing to OCR.
    case alreadySearchable
}

/// A job's lifecycle state. `ToolQueue` owns the `.queued`/`.running`/`.done`/`.failed`
/// transitions; `.analysing` is a view-model-only overlay — `ToolQueue` never produces it.
/// `CompressViewModel.publishJobs()` layers it onto a job that is still `.queued` in the queue
/// while a size estimate is in flight.
enum JobState: Equatable {
    case queued
    case analysing
    case running(Double)          // 0...1 fraction; use indeterminate UI when unknown
    case done(JobOutcome)
    case failed(String)           // user-facing failure message
}
