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

            Text("Free, private PDF tools for your Mac.\nEverything runs on-device — nothing is uploaded.")
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

            PrimaryButton(title: "Done") { dismiss() }
                .padding(.top, Theme.Spacing.small)
        }
        .padding(Theme.Spacing.large)
        .frame(width: 340)
        .background(Theme.Colors.surface)
    }
}

#Preview("About – Dark") {
    AboutView().preferredColorScheme(.dark)
}

#Preview("About – Light") {
    AboutView().preferredColorScheme(.light)
}
