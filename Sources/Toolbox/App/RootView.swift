// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The shell: a sidebar of tools beside the selected tool's detail view, with an
/// update banner across the top whenever a newer release exists.
struct RootView: View {
    @State private var selectedTool: Tool? = .compress
    @State private var sidebarCollapsed = false
    @StateObject private var updateChecker = UpdateChecker()

    var body: some View {
        VStack(spacing: 0) {
            if let release = updateChecker.available {
                UpdateBanner(release: release)
            }
            // An explicit split rather than NavigationSplitView: that container laid the sidebar
            // out a titlebar's height too high and, on a slightly-too-small window, collapsed it
            // to zero width — the app shipped looking as though it had no sidebar.
            HStack(spacing: 0) {
                SidebarView(selection: $selectedTool, isCollapsed: $sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 56 : 220)
                Divider()
                detail(for: selectedTool ?? .compress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: sidebarCollapsed ? 660 : 820, minHeight: 560)
        .onAppear { WindowSetup.applyMinimumSize(NSSize(width: 820, height: 560)) }
        .task { await updateChecker.check() }
    }

    @ViewBuilder
    private func detail(for tool: Tool) -> some View {
        switch tool {
        case .compress:
            CompressView()
        case .ocr:
            OCRView()
        }
    }
}

/// Full-width accent strip — deliberately unmissable (the owner's requirement: users must
/// not overlook updates). Notify-only: the button opens the release page; the app never
/// downloads or replaces its own binary (see `UpdateChecker`).
///
/// The solid accent background is a recorded DESIGN.md §7 exception (accent is otherwise
/// reserved for interactive elements): unmissability is the point, and the whole strip is
/// in service of one interaction. It appears at most once per release cycle.
private struct UpdateBanner: View {
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Toolbox \(release.version) is available.")
                .themeFont(.captionBold)
            Spacer(minLength: Theme.Spacing.small)
            Button {
                NSWorkspace.shared.open(release.pageURL)
            } label: {
                Text("Update")
                    .themeFont(.captionBold)
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
            .help("Open the release page")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.accent)
    }
}
