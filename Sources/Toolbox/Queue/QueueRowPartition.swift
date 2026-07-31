// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The single classification of a queue row that every "does this row need attention" consumer
/// must agree on. Before this type existed, the same predicate was hand-rolled three times —
/// `QueueViewModel.healthyQueuedCount`, `QueueView.screenState`, `QueueHeaderView.problemsSubtitle`
/// — and two of the three silently dropped the skip term, so a skipped `.failed` row (or a
/// skipped problem row, in the header's case) kept being counted as needing attention forever.
/// Every consumer now derives from `QueueRowPartition.classify`, so a future change to what
/// "resolved" means only has one place to change it.
enum QueueRowPartition: Equatable {
    /// A run-time terminal success (`.done`).
    case delivered
    /// A run-time terminal failure (`.failed`) the user has not skipped — still needs attention.
    case failedActionable
    /// A run-time terminal failure the user has skipped — resolved-by-skip, same as a skipped
    /// problem row.
    case failedSkipped
    /// An add-time inspection problem (locked/missing/unreadable) on a still-queued row, not yet
    /// skipped or fixed — needs attention.
    case problemUnresolved
    /// An add-time inspection problem the user has skipped — resolved-by-skip; the row stays
    /// `.queued` forever and never joins a run.
    case problemSkipped
    /// A queued/analysing row with no inspection problem — real, runnable work.
    case cleanPending
    /// `.running` — unreachable once the caller has already checked `isRunning`, kept here only
    /// for exhaustiveness at the row level.
    case transient

    /// Classifies one row given the inspection and skip state every consumer already carries.
    static func classify(job: ToolJob, inspections: [ToolJob.ID: RowInspection],
                         skipped: Set<ToolJob.ID>) -> QueueRowPartition {
        switch job.state {
        case .done:
            return .delivered
        case .failed:
            return skipped.contains(job.id) ? .failedSkipped : .failedActionable
        case .queued, .analysing:
            if inspections[job.id]?.problem != nil {
                return skipped.contains(job.id) ? .problemSkipped : .problemUnresolved
            }
            return .cleanPending
        case .running:
            return .transient
        }
    }
}
