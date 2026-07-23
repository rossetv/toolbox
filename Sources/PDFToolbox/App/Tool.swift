// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The tools hosted by the shell's sidebar.
///
/// Only tools that actually exist are listed. The spec's four-entry sidebar carried `merge` and
/// `split` as dimmed "Soon" placeholders; they were removed on the maintainer's instruction —
/// advertising a control that does nothing is worse than not showing it.
enum Tool: String, CaseIterable, Identifiable {
    case compress
    case ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .ocr: return "OCR"
        }
    }

    var systemImage: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .ocr: return "text.viewfinder"
        }
    }

    /// Tile colour. The mockup gives each tool its own coloured tile; these are iconography, not
    /// interactive accents, so DESIGN.md's single-accent rule for controls still holds.
    var tint: Color {
        switch self {
        case .compress: return Theme.Colors.documentBadge
        case .ocr: return Color(hex: 0x5856D6)
        }
    }
}
