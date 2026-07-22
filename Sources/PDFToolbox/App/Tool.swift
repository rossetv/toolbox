// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The tools hosted by the shell's sidebar.
///
/// `compress` and `ocr` are live in v1; `merge` and `split` are shown as dimmed
/// "Soon" placeholders (spec §7 — a fixed four-entry sidebar) and are not built.
enum Tool: String, CaseIterable, Identifiable {
    case compress
    case ocr
    case merge
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .ocr: return "OCR"
        case .merge: return "Merge"
        case .split: return "Split"
        }
    }

    var systemImage: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .ocr: return "text.viewfinder"
        case .merge: return "square.stack.3d.up.fill"
        case .split: return "square.split.2x1"
        }
    }

    /// Whether the tool is built and selectable in v1.
    var isAvailable: Bool {
        switch self {
        case .compress, .ocr: return true
        case .merge, .split: return false
        }
    }
}
