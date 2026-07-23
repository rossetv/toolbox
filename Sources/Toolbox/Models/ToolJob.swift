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
    var estimate: SizeEstimate?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.state = .queued
        self.resultURL = nil
        self.estimate = nil
    }
}
