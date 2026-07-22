// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// How a document's content is composed — drives the compression router. The colour vs
/// bilevel scan distinction is preserved for the deferred Rung 2/3 native pipelines; v1
/// routes every type to Rung-1 Ghostscript.
///
/// `.scanBilevel` is **content-based** (visually near-two-tone), not raw image bit-depth:
/// an 8-bit greyscale scan that is visually bilevel still classifies as `.scanBilevel`.
enum PDFContentType: Equatable {
    case bornDigital
    case mixedColour
    case scanColour
    case scanBilevel
}
