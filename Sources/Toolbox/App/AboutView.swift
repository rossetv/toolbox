// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The About sheet (handoff screen 11): app icon, name, version, links, copyright. Reads its
/// version from the bundle so it can never drift from what actually shipped; the "macOS 14 or
/// later" clause is static — it names this project's actual `project.yml` deployment target,
/// not a fact the running bundle can report about itself.
///
/// Presented as an IN-WINDOW overlay by `QueueView`, not a system sheet: `SheetChrome` already
/// draws the dim and the card, and a system sheet put a second container around them. Closing is
/// therefore a caller-supplied closure rather than `@Environment(\.dismiss)`, which is a no-op
/// outside a real presentation.
struct AboutView: View {
    let onClose: () -> Void

    /// Same ±1 pointer the empty state's icon leans on (DESIGN.md §9 11: "the app icon at 84pt
    /// (same parallax)"); the stage here is the card's own content.
    @State private var pointer: CGPoint?

    static let repositoryURL = URL(string: "https://github.com/rossetv/toolbox")!
    static let licenceURL = URL(string: "https://github.com/rossetv/toolbox/blob/main/LICENSE")!
    static let maintainerURL = URL(string: "mailto:toolbox@rosset.ie")!

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Version \(short) · macOS 14 or later"
    }

    var body: some View {
        SheetChrome(width: 330, topOffset: 130) {
            // Centre alignment throughout follows the macOS About-panel idiom (the system's own
            // About windows centre icon, name, version and copyright), not body copy — the
            // rewritten DESIGN.md (D4) carries no general no-centre rule for this to except
            // itself from.
            VStack(spacing: Theme.Spacing.small) {
                ParallaxAppIcon(size: 84, pointer: pointer)

                Text("Toolbox")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)

                Text(version)
                    .font(.system(size: 12.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textTertiary)

                Text("Free PDF tools that never phone home.\nNo account, no subscription, no watermark.")
                    .themeFont(.body13)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                // No `.focusEffectDisabled()` here any more: this view is presented inside the main
                // window, so `WindowSetup`'s stray-focus clear covers these links like every other
                // control (memory: stray-focus-ring invariant — the per-control hammer is exactly
                // what that invariant forbids reaching for).
                HStack(spacing: Theme.Spacing.medium) {
                    LinkButton(title: "Source Code") { NSWorkspace.shared.open(Self.repositoryURL) }
                    LinkButton(title: "Licence") { NSWorkspace.shared.open(Self.licenceURL) }
                    LinkButton(title: "Contact me") { NSWorkspace.shared.open(Self.maintainerURL) }
                }
                .padding(.top, Theme.Spacing.small)

                Text("© 2026 Vilmar Rosset · AGPL-3.0")
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.top, Theme.Spacing.small)
            }
            .padding(Theme.Spacing.large)
            .padding(.top, Theme.Spacing.small)
            .parallaxStage($pointer)
            // Full card width before the overlay: the text block is narrower than the 330pt card,
            // so a `.topTrailing` overlay measured against the block alone sat well short of the
            // card's right edge.
            .frame(maxWidth: .infinity)
            // Inside the chrome's CONTENT, not on `SheetChrome` itself: the chrome's root is a
            // window-filling ZStack (it draws the dim), so a `.topTrailing` overlay out there lands
            // in the window's corner rather than the card's.
            .overlay(alignment: .topTrailing) {
                PopoverCloseButton(action: onClose, style: .about)
                    .padding(.top, 14)
                    .padding(.trailing, 12)
            }
        }
    }
}

#Preview("About – Dark") {
    AboutView(onClose: {}).preferredColorScheme(.dark)
}

#Preview("About – Light") {
    AboutView(onClose: {}).preferredColorScheme(.light)
}
