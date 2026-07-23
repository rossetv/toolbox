// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The About sheet, opened from the sidebar's info button: app icon, name, version,
/// repository/licence links, maintainer and copyright. Reads its facts from the bundle
/// (icon, version) so it can never drift from what actually shipped.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    static let repositoryURL = URL(string: "https://github.com/rossetv/toolbox")!
    static let licenceURL = URL(string: "https://github.com/rossetv/toolbox/blob/main/LICENSE")!
    static let maintainerURL = URL(string: "mailto:toolbox@rosset.ie")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        // Centre alignment throughout is a deliberate DESIGN.md §7 exception: this is the
        // macOS About-panel idiom (the system's own About windows centre icon, name,
        // version and copyright), not body copy.
        VStack(spacing: Theme.Spacing.small) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            Text("Toolbox")
                .themeFont(.cardTitle)
                .foregroundStyle(Theme.Colors.text)

            Text(version)
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            Text("Free, private PDF tools for your Mac.\nEverything runs on-device — nothing is uploaded.\nOn launch the app only checks GitHub for new versions.")
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            HStack(spacing: Theme.Spacing.medium) {
                LinkButton(title: "GitHub") { NSWorkspace.shared.open(Self.repositoryURL) }
                LinkButton(title: "Licence (AGPL-3.0)") { NSWorkspace.shared.open(Self.licenceURL) }
                LinkButton(title: "Contact") { NSWorkspace.shared.open(Self.maintainerURL) }
            }
            // The sheet hands keyboard focus to its first control, which drew a permanent
            // focus ring around "GitHub". Links stay tabbable; only the ring is suppressed.
            .focusEffectDisabled()
            .padding(.top, Theme.Spacing.small)

            VStack(spacing: 2) {
                Text("Copyright © 2026 Vilmar Rosset")
                    .themeFont(.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Button {
                    NSWorkspace.shared.open(Self.maintainerURL)
                } label: {
                    Text("toolbox@rosset.ie")
                        .themeFont(.micro)
                        .foregroundStyle(Theme.Colors.link)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointingHandCursor()
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Spacing.small)

        }
        .padding(Theme.Spacing.large)
        .padding(.top, Theme.Spacing.small)
        .frame(width: 340)
        .background(Theme.Colors.surface)
        .overlay(alignment: .topTrailing) {
            CloseButton { dismiss() }
                .padding(10)
        }
    }
}

/// The modal close affordance: a quiet circular ✕ that brightens on hover, per DESIGN.md's
/// dark-modal close-button hover token. Esc closes too (`cancelAction`).
private struct CloseButton: View {
    let action: () -> Void
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
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel("Close")
    }
}

#Preview("About – Dark") {
    AboutView().preferredColorScheme(.dark)
}

#Preview("About – Light") {
    AboutView().preferredColorScheme(.light)
}
