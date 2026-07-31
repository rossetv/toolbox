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
/// `init()` stays no-arg: `SidebarView` still presents this exact construction via `.sheet(…)`
/// until I1b deletes it, so the double chrome that produces (this view's own `SheetChrome` INSIDE
/// the system sheet) is a known, temporary artefact of that legacy call site — the eventual
/// unified-queue shell (I1a) presents it directly, without the system sheet wrapper.
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
            CloseButton { dismiss() }
                .padding(20)
        }
    }
}

/// The modal close affordance: a quiet circular ✕ that brightens on hover — the About sheet's
/// content is app-layer composition, not a DESIGN.md-pinned component (§4.3). Esc closes too
/// (`cancelAction`). Its own
/// `.focusEffectDisabled()` is the THIRD of this file's three (with the two link groups above)
/// — this sheet gets no `WindowSetup` stray-focus clearing (memory: stray-focus-ring invariant),
/// so every focusable control here independently refuses the ring AppKit auto-assigns on open.
private struct CloseButton: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovering ? Theme.Colors.text : Theme.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Theme.Colors.text.opacity(isHovering ? 0.32 : 0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(MotionButtonStyle())
        .focusEffectDisabled()
        .pointingHandCursor()
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .continuousHover($isHovering)
        // Was a bare 0.12s literal that ran regardless of Reduce Motion — the one animation in
        // the app that never asked.
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityLabel("Close")
    }
}

#Preview("About – Dark") {
    AboutView().preferredColorScheme(.dark)
}

#Preview("About – Light") {
    AboutView().preferredColorScheme(.light)
}
