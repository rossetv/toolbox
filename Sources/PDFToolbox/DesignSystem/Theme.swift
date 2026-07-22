// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// Design token stub (Phase 0). The full token set and reusable components land in
/// Track D (Task D.1) built from `DESIGN.md`; Phase-0/1 views reference only this stub
/// so the tracks stay file-disjoint until the S.1 polish pass.
enum Theme {
    enum Colors {
        /// Apple light-gray section background (`#f5f5f7`).
        static let background = Color(hex: 0xF5F5F7)
        /// Near-black primary text (`#1d1d1f`).
        static let text = Color(hex: 0x1D1D1F)
        /// Apple Blue — the single chromatic accent (`#0071e3`).
        static let accent = Color(hex: 0x0071E3)
    }

    enum Radius {
        /// Full pill (Apple CTA radius).
        static let pill: CGFloat = 980
        static let card: CGFloat = 12
        static let control: CGFloat = 8
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }
}

extension Color {
    /// Build a colour from a 24-bit RGB hex literal, e.g. `Color(hex: 0x0071E3)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
