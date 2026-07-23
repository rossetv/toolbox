// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// A pre-compression size prediction (spec §5.3). Defined here in the shared layer; the
/// estimator (Track C, Task C.2) implements against this type.
struct SizeEstimate: Equatable {
    let predictedBytes: Int
    let confidence: Confidence
    /// True when per-file analysis was abandoned (too slow / too uncertain) and a
    /// typical-range fallback was used instead.
    let isFallback: Bool
}

enum Confidence: Equatable {
    case high, medium, low
}
