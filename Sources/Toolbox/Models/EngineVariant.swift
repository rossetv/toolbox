// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Which engine leg produced a version. `.plain` covers every non-MRC engine result — the
/// Ghostscript output and the Rung-2 CCITT rebuild alike — because the only distinction the
/// estimate calibration needs (R16) is whether the MRC leg shipped this version.
enum EngineVariant: Equatable {
    case mrc
    case plain
    /// The untouched input, parked when the gs leg bloated and there was nothing legitimate to
    /// offer as an alternative (R6/R7).
    case original
}
