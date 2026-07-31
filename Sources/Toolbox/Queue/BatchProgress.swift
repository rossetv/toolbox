// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The Working screen's aggregate figures (spec §6.8/§7), computed by `QueueViewModel` from every
/// row the current (or most recently run) batch is made of.
///
/// Persists after the batch ends — until the queue is cleared (`QueueViewModel.clearFinished()`
/// resets it to `nil`) — because the Finished header (screen 06) reads `savedSoFarBytes` as its
/// "N MB lighter" headline, the SAME figure the Working header showed as "N MB saved so far".
/// Everything else on the Finished header — before/after totals, file count, searchable count —
/// is computed FROM ROWS, never from here (spec §7/§10): this type owns exactly one number the
/// rows cannot cheaply re-derive on every render, plus the run's live fraction and ETA.
struct BatchProgress: Equatable {
    /// 0...1, the fraction of the batch's rows completed. A row still in flight contributes its
    /// own live (composed, both-legs-continuous) fraction rather than 0 — always 1 once the batch
    /// has finished. Not necessarily monotonic across a run: a file dropped in mid-batch (spec
    /// §6.5's drag-during-run) grows the denominator, which can make this dip before it recovers.
    let fraction: Double
    /// Seconds until the batch finishes, or nil before 10% of it has completed — the honest-
    /// progress rule (v1 §8) never fabricates an estimate from too little evidence. Smoothed and
    /// clamped to never increase while the batch runs (spec §6.8's "monotonic display").
    let etaSeconds: Int?
    /// Bytes saved so far, summed over rows whose compress leg actually shipped a smaller file.
    /// An OCR-only delivery, a compress-failure rescue and a noGain(+OCR) row all record no
    /// shipped `VersionStore` entry (spec §6.5) and so contribute zero here.
    let savedSoFarBytes: Int
}
