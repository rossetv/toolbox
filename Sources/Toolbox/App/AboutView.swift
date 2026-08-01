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
/// `init()` stays no-arg: `QueueView` presents this exact construction via `.sheet(item:)`, so
/// this view's own `SheetChrome` sits inside the system sheet — the double chrome is a known,
/// accepted shape of that call site, not a temporary artefact.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

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
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)

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

                HStack(spacing: Theme.Spacing.medium) {
                    // Two link groups, each with its own `.focusEffectDisabled()` — preserved
                    // from the incumbent shape (which split GitHub+Licence from the standalone
                    // email link) rather than folded into one call: this off-net sheet gets no
                    // `WindowSetup` clearing (memory: stray-focus-ring invariant), so every
                    // focusable control here must independently refuse the ring AppKit would
                    // otherwise auto-assign on open, in case a future edit ever separates them.
                    HStack(spacing: Theme.Spacing.medium) {
                        LinkButton(title: "Source Code") { NSWorkspace.shared.open(Self.repositoryURL) }
                        LinkButton(title: "Licence") { NSWorkspace.shared.open(Self.licenceURL) }
                    }
                    .focusEffectDisabled()
                    LinkButton(title: "Contact me") { NSWorkspace.shared.open(Self.maintainerURL) }
                        .focusEffectDisabled()
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
        }
        .overlay(alignment: .topTrailing) {
            // `.about` style: this sheet gets no `WindowSetup` stray-focus clearing (memory:
            // stray-focus-ring invariant), so its own `.focusEffectDisabled()` — the third of this
            // file's three, with the two link groups above — is load-bearing, not decorative.
            PopoverCloseButton(action: { dismiss() }, style: .about)
                .padding(20)
        }
    }
}

#Preview("About – Dark") {
    AboutView().preferredColorScheme(.dark)
}

#Preview("About – Light") {
    AboutView().preferredColorScheme(.light)
}
