// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The app's design tokens — matching `DESIGN.md`'s token tables (the law), itself rewritten
/// for the unified-queue redesign from the Claude Design handoff, kept outside this repository.
/// Phase 0 shipped a stub (`Colors.background/text/accent`, `Radius.pill/card/control`,
/// `Spacing.small/medium/large`) so Tracks B/C could style early views without depending on
/// Track D; those names and types are preserved unchanged below — only expanded.
///
/// ## Handoff → identifier mapping (F7)
///
/// The redesign handoff (`$(git rev-parse --path-format=absolute --git-common-dir)/lcw/…/handoff/README.md`
/// §Design Tokens) names its tokens differently to this file's incumbents. Every handoff name
/// maps onto an EXISTING identifier below where one already exists — no renames, because
/// `background`/`textSecondary`/`textTertiary` are read at 19 call sites across five files
/// outside this task's scope. New identifiers are added only where the handoff has no
/// incumbent to re-value.
///
/// **Colors**: `bg`→`background`, `surface`→`surface`, `text`→`text`, `text2`→`textSecondary`,
/// `text3`→`textTertiary`, `accent`→`accent` (gains a dark variant), `link`→`link`,
/// `success`→`success` (gains a dark variant); no incumbent, so NEW: `warn`, `danger`,
/// `stroke`, `sep`, `hairline`, `fill`, `track`. `documentBadge` is not a handoff token (PDF
/// file-type iconography) and is untouched.
///
/// **Radius**: `capsule`(980)→`pill`, `popover`(12)→`card`; no incumbent, so NEW: `row`(10),
/// `sheet`(14). `input`(11) and `control`(8, already the handoff's `control` value) are
/// untouched — `input` has no handoff counterpart and stays for `SegmentedPreset`/`Card`.
///
/// **Typography**: the incumbent `caption` case is RE-VALUED to the handoff's small-caption
/// size (11.5 — distinct from the new `meta` case's 12, so the two don't collide); every
/// surviving `.themeFont(.caption)` call site was checked for this re-value (still reads
/// correctly smaller: `Components.swift`'s `Card`/`DropZone`/`ToolHeader` captions, all
/// secondary/fine-print text that only gets more legible at the handoff's actual size). NEW
/// cases added for shapes with no incumbent: `windowHeadline`, `sheetTitle`, `rowName`,
/// `bodyStrong`, `body13`, `meta`, `sectionLabel`.
///
/// **Motion**: NEW `Theme.Motion` enum — the handoff has no incumbent motion tokens at all.
enum Theme {
    enum Colors {
        /// App canvas: the sidebar/window background, and the recessed "grouped" fill used by
        /// rows sitting on top of a `surface` (e.g. `FileRow`, the save-to control) — handoff
        /// `bg` (`#f5f5f7` light / `#1c1c1e` dark). In the mockup this single tone does double
        /// duty as both the sidebar canvas and the grey row fill inside a white content pane —
        /// reproduced here as one token rather than two.
        static let background = Color(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x1C1C1E))

        /// Elevated content surface sitting on top of `background` — the detail pane and card
        /// containers (`Card`, `DropZone`, unselected `SegmentedPreset` options). Handoff
        /// `surface` (`#ffffff` light / `#242426` dark).
        static let surface = Color(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x242426))

        /// Primary text (handoff `text`: near-black `#1d1d1f` light / white dark).
        static let text = Color(light: NSColor(hex: 0x1D1D1F), dark: NSColor.white)

        /// Secondary text — captions, metadata (handoff `text2`: black 80% light / white 80%
        /// dark).
        static let textSecondary = Color(
            light: NSColor(hex: 0x000000, alpha: 0.8),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.8)
        )

        /// Tertiary text — disabled states, fine print (handoff `text3`: black 48% light /
        /// white 48% dark).
        static let textTertiary = Color(
            light: NSColor(hex: 0x000000, alpha: 0.48),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.48)
        )

        /// Apple Blue — the single chromatic accent. Reserved for interactive elements only
        /// (DESIGN.md §7 Do/Don't). Handoff `accent`: `#0071e3` light / `#0a84ff` dark
        /// (`controlAccentColor`/system blue) — the redesign gives this a dark variant the
        /// earlier stub didn't have.
        static let accent = Color(light: NSColor(hex: 0x0071E3), dark: NSColor(hex: 0x0A84FF))

        /// Inline text links (handoff `link`: `#0066cc` light / `#2997ff` dark) — distinct from
        /// `accent`, used for "+ Add", "Clear", "Change…" style affordances.
        static let link = Color(light: NSColor(hex: 0x0066CC), dark: NSColor(hex: 0x2997FF))

        /// Semantic success/complete state — a status colour, not the interactive accent; used
        /// for saved badges and completion ticks. Handoff `success`: `#34c759` light /
        /// `#32d74b` dark (system green) — gains a dark variant the earlier stub didn't have.
        static let success = Color(light: NSColor(hex: 0x34C759), dark: NSColor(hex: 0x32D74B))

        /// Partial-result / needs-attention tint (handoff `warn`, system orange). Identical in
        /// both appearances per the handoff's own token table — a single constant, not a
        /// `light:dark:` pair, is the correct reproduction; don't "helpfully" split it.
        static let warn = Color(hex: 0xFF9F0A)

        /// Password/error row tint (handoff `danger`: `#d70015` light / `#ff453a` dark, system
        /// red).
        static let danger = Color(light: NSColor(hex: 0xD70015), dark: NSColor(hex: 0xFF453A))

        /// Control border / inset ring (handoff `stroke`: black 16.8% light / white 16.8% dark).
        static let stroke = Color(
            light: NSColor(hex: 0x000000, alpha: 0.168),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.168)
        )

        /// 1px section separator (handoff `sep`: black 12% light / white 12% dark).
        static let sep = Color(
            light: NSColor(hex: 0x000000, alpha: 0.12),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.12)
        )

        /// Inset hairline, fainter than `sep` (handoff `hairline`: black 9.6% light / white
        /// 9.6% dark).
        static let hairline = Color(
            light: NSColor(hex: 0x000000, alpha: 0.096),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.096)
        )

        /// Quiet control fill — hover backgrounds, capsule chips at rest (handoff `fill`: an
        /// off-black tint at 6% light, plain white at 10% dark — deliberately asymmetric, not a
        /// black/white mirror like `stroke`/`sep`/`hairline`, so don't "fix" it into one).
        static let fill = Color(
            light: NSColor(hex: 0x1D1D1F, alpha: 0.06),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.1)
        )

        /// Progress-bar track (handoff `track`: an off-black tint at 12% light, white 12% dark).
        static let track = Color(
            light: NSColor(hex: 0x1D1D1F, alpha: 0.12),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.12)
        )

        /// PDF file-type iconography (`#ff3b30`) — matches macOS's own red PDF document colour
        /// coding. This is iconography, not an interactive accent, so it sits outside DESIGN.md's
        /// single-accent rule and outside the handoff's token table; used only for the file-type
        /// badge in `FileRow`/`PDFThumbnail`.
        static let documentBadge = Color(hex: 0xFF3B30)
    }

    enum Radius {
        /// Full pill (handoff `capsule`, 980px) — the *link* CTAs ("Learn more"/"Shop"),
        /// compact badges (`StatPill`, `CapsuleBadge`), and toggle tracks.
        static let pill: CGFloat = 980
        /// Standard card/popover corner (handoff `popover`, 12px).
        static let card: CGFloat = 12
        /// Comfortable corner for controls (DESIGN.md "Comfortable") — preset cards, the
        /// save-to row, search/filter-style inputs. No handoff counterpart; unchanged.
        static let input: CGFloat = 11
        /// Control/chip corner (handoff `control`, 8px) — buttons, verb chips.
        static let control: CGFloat = 8
        /// Row and option-card corner (handoff, 10px) — `QueueRow`, `OptionCard`, `VariantCard`.
        static let row: CGFloat = 10
        /// Sheet corner (handoff, 14px) — `SheetChrome`.
        static let sheet: CGFloat = 14
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }

    /// Generic elevation shadow retained from before the redesign. DESIGN.md §11 flags this
    /// token as having no per-context counterpart in the handoff — every context §6 actually
    /// names (popover/sheet/secondary-button/`PDFThumbnail`) sizes its own inline shadow — and
    /// with `Card` deleted at I1b this has no current consumer; kept as-is pending that
    /// follow-up. Never stack multiple shadows if it is ever revived.
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
        /// NEW cases (F7) — handoff shapes with no incumbent. See the mapping comment atop
        /// `Theme` for why `caption` (11.5) and `meta` (12) are deliberately two sizes apart.
        case windowHeadline, sheetTitle, rowName, bodyStrong, body13, meta, sectionLabel

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
            // Re-valued (F7): handoff captions run 11.5–12; 11.5 is the size actually used
            // throughout (popover/radio-row subtitles, batch-card timestamps) — `meta` (below)
            // takes the other end of that range, so the two roles stay visually distinct.
            case .caption: return .system(size: 11.5, weight: .regular)
            case .captionBold: return .system(size: 14, weight: .semibold)
            case .micro: return .system(size: 12, weight: .regular)
            case .microBold: return .system(size: 12, weight: .semibold)
            case .nano: return .system(size: 10, weight: .regular)
            // NEW (F7):
            case .windowHeadline: return .system(size: 22, weight: .semibold)   // "3 files", "32.6 MB lighter"
            case .sheetTitle: return .system(size: 17, weight: .semibold)       // "Recent batches", "Different quality for these 3 files"
            case .rowName: return .system(size: 15, weight: .semibold)         // queue row filename
            case .bodyStrong: return .system(size: 13, weight: .semibold)      // "3 files in Contracts", footer totals
            case .body13: return .system(size: 13, weight: .regular)          // plain 13pt figures (current size, arrow-separated sizes)
            case .meta: return .system(size: 12, weight: .regular)            // row descriptive meta line ("48 pages, mostly photographs")
            case .sectionLabel: return .system(size: 11, weight: .semibold)   // "QUALITY", "TODAY" group labels
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
            // Re-valued (F7): the handoff's document-wide default tracking (-0.2px), which every
            // caption-sized text in it inherits rather than overriding individually.
            case .caption: return -0.2
            case .captionBold: return -0.224
            case .micro: return -0.12
            case .microBold: return -0.12
            case .nano: return -0.08
            // NEW (F7): handoff explicit trackings per role; unlabelled small text inherits the
            // document's -0.2px default, which `bodyStrong`/`body13`/`meta` also use.
            case .windowHeadline: return -0.3
            case .sheetTitle: return -0.2
            case .rowName: return -0.2
            case .bodyStrong: return -0.2
            case .body13: return -0.2
            case .meta: return -0.2
            case .sectionLabel: return 0.4
            }
        }
    }

    /// Animation durations, the transform values that go with them, and the Reduce Motion gates
    /// every animated surface asks — from the handoff's "Animations (durations & easings)"
    /// section and its per-control hover/active CSS (DESIGN.md §8). No incumbent tokens existed
    /// for motion before F7; the values and gates below arrived with the 2026-08-01 motion-polish
    /// mandate (DECISIONS.md). Every interactive view gates its use of these on
    /// `accessibilityReduceMotion`, substituting a plain (or no) transition rather than skipping
    /// the state change itself.
    enum Motion {
        /// The handoff's "standard curve" (`cubic-bezier(.2,.8,.25,1)`), reproduced as its stated
        /// SwiftUI spring equivalent. `standardResponse`/`standardDamping` are exposed alongside
        /// `standard` so tests can pin the digits without relying on `Animation`'s `Equatable`
        /// conformance reaching into the spring's internals.
        static let standardResponse: Double = 0.35
        static let standardDamping: Double = 0.85
        static var standard: Animation { .spring(response: standardResponse, dampingFraction: standardDamping) }

        /// Hover background/opacity transitions.
        static let hover: Double = 0.15
        /// Primary-button press scale.
        static let press: Double = 0.12
        /// Popover fade + scale + translate.
        static let popover: Double = 0.3
        /// Sheet fade + rise + scale.
        static let sheet: Double = 0.38
        /// Update banner slide-down.
        static let banner: Double = 0.45
        /// Success/warn check "pop" (scale .4→1.16→1).
        static let checkPop: Double = 0.45

        // MARK: values

        /// Filled-button hover fade (handoff `opacity:.9`).
        static let hoverOpacity: Double = 0.9
        /// Filled-CTA hover rise (handoff `transform:translateY(-1px)`) — negative is up.
        static let hoverLift: CGFloat = -1
        /// Pressed scale for every button. The handoff writes `scale(.97)` on four of its six
        /// primary buttons and `.98` on the other two; one token at .97 is the deliberate
        /// consolidation (DESIGN.md §8) — a second constant for a 0.01 delta nobody can see is
        /// magic-number scatter, not fidelity.
        static let pressScale: CGFloat = 0.97
        /// Text-link hover/press fade (handoff `opacity:.6` on the "+ Add"/"⊗ Clear"/"Cancel"
        /// spans).
        static let linkHoverOpacity: Double = 0.6
        /// Progress bar leading-cap glow pulse (handoff `@keyframes capGlow`: opacity .35→.95,
        /// 1.6s ease-in-out infinite, autoreversing). Decorative — gated on Reduce Motion.
        static let capGlow: Double = 1.6

        // MARK: Reduce Motion gates
        //
        // Every animated surface asks one of these rather than writing its own
        // `reduceMotion ? nil : …` ternary, so "Reduce Motion means static" is decided in one
        // place and is directly testable (`ThemeTests`) without rendering a view.

        /// The hover curve, or `nil` (no animation — the state change still happens instantly).
        static func hoverCurve(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: hover)
        }

        /// The press curve, or `nil`.
        static func pressCurve(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: press)
        }

        /// The standard spring, or `nil` — screen/row transitions and selection changes.
        static func standardCurve(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : standard
        }

        /// Pressed scale, flattened to 1 under Reduce Motion (a transform, so it goes).
        static func scale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
            isPressed && !reduceMotion ? pressScale : 1
        }

        /// Hover lift, flattened to 0 under Reduce Motion. A pressed control sits back at rest
        /// even while hovered — the handoff's active rule is `translateY(0) scale(.97)`.
        static func lift(isHovering: Bool, isPressed: Bool = false, reduceMotion: Bool) -> CGFloat {
            isHovering && !isPressed && !reduceMotion ? hoverLift : 0
        }
    }
}

extension Text {
    /// Applies a DESIGN.md type role's font + tracking + numeric styling together. `Text`-only:
    /// SwiftUI's `tracking(_:)`/`kerning(_:)` modifiers exist on `Text`, not on `View` in
    /// general — for non-`Text` views (e.g. an SF Symbol `Label`'s icon), use
    /// `Theme.Typography.role.font` directly with `.font(_:)`. Every text rendered via this
    /// method gets `.monospacedDigit()` applied universally — DESIGN.md §1 & §7 require all
    /// numeric values to use tabular-number spacing (§1: "Every number on screen — sizes,
    /// percentages, counts, timings — is `.monospacedDigit()`"), matching the HTML handoff's
    /// universal `font-variant-numeric:tabular-nums` scope.
    func themeFont(_ style: Theme.Typography) -> Text {
        self.font(style.font).tracking(style.tracking).monospacedDigit()
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
