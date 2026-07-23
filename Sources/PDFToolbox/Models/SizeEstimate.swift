// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// A pre-compression size prediction, shown to the user before a job runs.
struct SizeEstimate: Equatable {
    let predictedBytes: Int
    /// True when per-file analysis was abandoned (too slow, or too uncertain) and a
    /// typical-range fallback was used instead. The UI marks such a figure as approximate.
    let isFallback: Bool
}
