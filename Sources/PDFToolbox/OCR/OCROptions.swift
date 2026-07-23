// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// User-tunable OCR settings (spec §6). `languages` empty means auto-detect.
struct OCROptions: Equatable {
    var accuracy: Accuracy = .accurate
    var languages: [String] = []
}

/// Vision's recognition level: `.fast` trades accuracy for speed; `.accurate` is the default.
enum Accuracy: String, CaseIterable, Identifiable {
    case fast
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .accurate: return "Accurate"
        }
    }
}
