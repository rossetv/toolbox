// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// One file in a tool's batch queue. `ToolQueue` mutates `state`/`resultURL`; the estimate
/// is filled in by the compress estimator where applicable.
struct ToolJob: Identifiable {
    let id: UUID
    let url: URL
    var state: JobState
    var resultURL: URL?
    var alternateURL: URL?
    var estimate: SizeEstimate?
    /// The MRC per-page classifier/verifier verdicts for this job, when the compress body produced
    /// one (spec §6's debugging record). Absent for OCR jobs and any compress job that never
    /// reached the MRC leg.
    var mrcReport: MRCDocumentReport?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.state = .queued
        self.resultURL = nil
        self.alternateURL = nil
        self.estimate = nil
        self.mrcReport = nil
    }
}
