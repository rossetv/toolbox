// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The app's design tokens — built from `DESIGN.md` (Apple's design language, the law) and
/// the Claude Design mockup, kept outside this repository (matching its feel).
/// Phase 0 shipped a stub (`Colors.background/text/accent`, `Radius.pill/card/control`,
/// `Spacing.small/medium/large`) so Tracks B/C could style early views without depending on
/// Track D; those names and types are preserved unchanged below — only expanded.
enum Theme {
    enum Colors {
        /// App canvas: the sidebar/window background, and the recessed "grouped" fill used by
        /// rows sitting on top of a `surface` (e.g. `FileRow`, the save-to control) — DESIGN.md's
        /// light-gray/pure-black section pair (`#f5f5f7` / `#000000`). In the mockup this single
        /// tone does double duty as both the sidebar canvas and the grey row fill inside a white
        /// content pane — reproduced here as one token rather than two.
        static let background = Color(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x000000))

        /// Elevated content surface sitting on top of `background` — the detail pane and card
        /// containers (`Card`, `DropZone`, unselected `SegmentedPreset` options). White in light
        /// mode (native macOS content), DESIGN.md "Dark Surface 1" (`#272729`) in dark mode.
        static let surface = Color(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x272729))

        /// Primary text (DESIGN.md §2 "Text": near-black `#1d1d1f` light / white dark).
        static let text = Color(light: NSColor(hex: 0x1D1D1F), dark: NSColor.white)

        /// Secondary text — captions, metadata (DESIGN.md "Black 80%"; dark value mirrors it at
        /// the same opacity, which DESIGN.md doesn't give explicitly but is the standard Apple
        /// HIG symmetric-opacity convention for label hierarchy).
        static let textSecondary = Color(
            light: NSColor(hex: 0x000000, alpha: 0.8),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.8)
        )

        /// Tertiary text — disabled states, fine print (DESIGN.md "Black 48%", mirrored in dark
        /// mode per the same convention as `textSecondary`).
        static let textTertiary = Color(
            light: NSColor(hex: 0x000000, alpha: 0.48),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.48)
        )

        /// Apple Blue — the single chromatic accent (`#0071e3`). Reserved for interactive
        /// elements only (DESIGN.md §7 Do/Don't); constant across appearances since DESIGN.md
        /// does not vary it for dark mode.
        static let accent = Color(hex: 0x0071E3)

        /// Inline text links (DESIGN.md "Link Blue" `#0066cc` light / "Bright Blue" `#2997ff`
        /// dark) — distinct from `accent`, used for "+ Add", "Clear", "Change…" style affordances.
        static let link = Color(light: NSColor(hex: 0x0066CC), dark: NSColor(hex: 0x2997FF))

        /// Semantic success/complete state (`#34c759`) — a status colour, not the interactive
        /// accent; used for saved badges and completion ticks (DESIGN.md doesn't spend the
        /// chromatic accent budget on it, but Apple's own HIG reserves systemGreen for exactly
        /// this "done/success" role alongside a single brand accent).
        static let success = Color(hex: 0x34C759)

        /// PDF file-type iconography (`#ff3b30`) — matches macOS's own red PDF document colour
        /// coding. This is iconography, not an interactive accent, so it sits outside DESIGN.md's
        /// single-accent rule; used only for the file-type badge in `FileRow`.
        static let documentBadge = Color(hex: 0xFF3B30)
    }

    enum Radius {
        /// Full pill (DESIGN.md's 980px) — the *link* CTAs ("Learn more"/"Shop") and compact
        /// badges such as `StatPill`. Not the primary button: DESIGN.md §4 gives that `control`
        /// (8px), and the mockup agrees.
        static let pill: CGFloat = 980
        /// Standard card/button corner. DESIGN.md's Do/Don't caps rectangular corners at 12px
        /// (980 reserved for pills), so this is also the ceiling for any rectangular container —
        /// the mockup's 16px drop-zone corner is intentionally not reproduced literally.
        static let card: CGFloat = 12
        /// Comfortable corner for controls (DESIGN.md "Comfortable") — preset cards, the
        /// save-to row, search/filter-style inputs.
        static let input: CGFloat = 11
        static let control: CGFloat = 8
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }

    /// DESIGN.md §6 — one soft, sparse shadow, used only where an element needs to visually
    /// lift off its surface. Most elements have none; opt in per-component (e.g. `Card(elevated:
    /// true)`), never stack multiple shadows.
    enum Shadow {
        static let color = Color.black.opacity(0.22)
        static let radius: CGFloat = 15
        static let x: CGFloat = 3
        static let y: CGFloat = 5
    }

    /// DESIGN.md §3's type hierarchy. SwiftUI's system font already performs San Francisco's
    /// optical-size switch (Text ↔ Display) at the OS level for any `.system(size:)` request, so
    /// a single call respects the "Display ≥20 / Text <20" rule without naming the family
    /// explicitly — naming "SF Pro Display"/"SF Pro Text" directly would risk a missing-font
    /// fallback SwiftUI doesn't need here.
    ///
    /// Line-height is intentionally not reproduced per role: SwiftUI's `lineSpacing` adds to a
    /// font's natural leading rather than replacing the CSS line-box the way DESIGN.md's values
    /// are specified, so a naive px→points copy would be silently wrong. Every current consumer
    /// is single-line; multi-line tuning is deferred to the S.1 polish pass where real paragraph
    /// content exists to check it against.
    enum Typography {
        case displayHero, sectionHeading, tileHeading, cardTitle, subheading
        case navHeading, subNav, body, bodyEmphasis, buttonLarge, button
        case link, caption, captionBold, micro, microBold, nano

        var font: Font {
            switch self {
            case .displayHero: return .system(size: 56, weight: .semibold)
            case .sectionHeading: return .system(size: 40, weight: .semibold)
            case .tileHeading: return .system(size: 28, weight: .regular)
            case .cardTitle: return .system(size: 21, weight: .bold)
            case .subheading: return .system(size: 21, weight: .regular)
            case .navHeading: return .system(size: 34, weight: .semibold)
            case .subNav: return .system(size: 24, weight: .light)
            case .body: return .system(size: 17, weight: .regular)
            case .bodyEmphasis: return .system(size: 17, weight: .semibold)
            case .buttonLarge: return .system(size: 18, weight: .light)
            case .button: return .system(size: 17, weight: .regular)
            case .link: return .system(size: 14, weight: .regular)
            case .caption: return .system(size: 14, weight: .regular)
            case .captionBold: return .system(size: 14, weight: .semibold)
            case .micro: return .system(size: 12, weight: .regular)
            case .microBold: return .system(size: 12, weight: .semibold)
            case .nano: return .system(size: 10, weight: .regular)
            }
        }

        /// DESIGN.md's negative (and occasionally positive) letter-spacing, verbatim per role.
        var tracking: CGFloat {
            switch self {
            case .displayHero: return -0.28
            case .sectionHeading: return 0
            case .tileHeading: return 0.196
            case .cardTitle: return 0.231
            case .subheading: return 0.231
            case .navHeading: return -0.374
            case .subNav: return 0
            case .body: return -0.374
            case .bodyEmphasis: return -0.374
            case .buttonLarge: return 0
            case .button: return 0
            case .link: return -0.224
            case .caption: return -0.224
            case .captionBold: return -0.224
            case .micro: return -0.12
            case .microBold: return -0.12
            case .nano: return -0.08
            }
        }
    }
}

extension Text {
    /// Applies a DESIGN.md type role's font + tracking together. `Text`-only: SwiftUI's
    /// `tracking(_:)`/`kerning(_:)` modifiers exist on `Text`, not on `View` in general — for
    /// non-`Text` views (e.g. an SF Symbol `Label`'s icon), use `Theme.Typography.role.font`
    /// directly with `.font(_:)`.
    func themeFont(_ style: Theme.Typography) -> Text {
        self.font(style.font).tracking(style.tracking)
    }
}

extension Color {
    /// Build a colour from a 24-bit RGB hex literal, e.g. `Color(hex: 0x0071E3)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// A colour that switches between `light` and `dark` `NSColor` as the system/window
    /// appearance changes. The pair is wrapped in an `NSColor` dynamic provider, which AppKit
    /// resolves lazily at draw time against the current effective appearance — so a single
    /// `static let` built once stays correct across live appearance switches (System Settings →
    /// Appearance, or per-window overrides) with no extra plumbing on the call site.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    /// Build an `NSColor` from a 24-bit RGB hex literal, e.g. `NSColor(hex: 0x0071E3)`.
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
