// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Measured per-page signals the classifier bases its verdict on. Retained on the job's
/// MRCDocumentReport — the app has no logging facility; this IS the debugging record (spec §6).
struct MRCPageFeatures: Equatable {
    /// Fraction of sampled pixels counted as ink (dark against local background), 0…1.
    let inkCoverage: Double
    /// Mean area (px) of ink connected components at the classifier's render scale.
    let meanComponentSize: Double
    let componentCount: Int
    /// Fraction of sampled pixels that are chromatic (max channel delta above threshold), 0…1.
    let colourCoverage: Double
    /// Fraction of sampled pixels that are even moderately chromatic (max channel delta > 25) —
    /// the signal that catches pale fine-pattern backgrounds (guilloche and similar) which sit
    /// below `colourCoverage`'s delta but are destroyed by the fg/bg split. A strict superset of
    /// `colourCoverage`'s pixels by construction.
    let moderateChromaCoverage: Double
}

enum MRCDeclineReason: Equatable {
    case complexPage        // text layer / vector content / not exactly one image (R2)
    case renderFailed
    case notTextDominant    // classifier signals outside the eligible envelope (R3)
    case chromaPattern      // pale fine-pattern background (e.g. guilloche) — MRC would blur it
    case segmentationFailed
    case encodeFailed
    case verifierRejected(score: Double)
}

enum MRCPageVerdict: Equatable {
    case mrcEncoded(MRCPageFeatures)
    case fallback(MRCDeclineReason)
}

/// One entry per input page, in page order; attached to the compress result for tests/debugging.
struct MRCDocumentReport: Equatable {
    let verdicts: [MRCPageVerdict]
    var mrcPageCount: Int {
        verdicts.filter { if case .mrcEncoded = $0 { return true } else { return false } }.count
    }
}
