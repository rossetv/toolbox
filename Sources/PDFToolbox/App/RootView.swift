// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The shell: a sidebar of tools beside the selected tool's detail view.
struct RootView: View {
    @State private var selectedTool: Tool? = .compress
    @State private var sidebarCollapsed = false

    var body: some View {
        // An explicit split rather than NavigationSplitView: that container laid the sidebar out
        // a titlebar's height too high and, on a slightly-too-small window, collapsed it to zero
        // width — the app shipped looking as though it had no sidebar.
        HStack(spacing: 0) {
            SidebarView(selection: $selectedTool, isCollapsed: $sidebarCollapsed)
                .frame(width: sidebarCollapsed ? 56 : 220)
            Divider()
            detail(for: selectedTool ?? .compress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: sidebarCollapsed ? 736 : 900, minHeight: 620)
        .onAppear { WindowSetup.applyMinimumSize(NSSize(width: 900, height: 620)) }
    }

    @ViewBuilder
    private func detail(for tool: Tool) -> some View {
        switch tool {
        case .compress:
            CompressView()
        case .ocr:
            OCRView()
        case .merge, .split:
            PlaceholderToolView(tool: tool)
        }
    }
}

/// Detail shown for the two tools that aren't built in v1.
private struct PlaceholderToolView: View {
    let tool: Tool

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ToolIconTile(systemImage: tool.systemImage, size: 56)
                .opacity(0.45)
            VStack(spacing: 4) {
                Text(tool.title).themeFont(.tileHeading).foregroundStyle(Theme.Colors.text)
                Text("Coming soon.").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surface)
        .navigationTitle(tool.title)
    }
}

#Preview("Placeholder – Light") {
    PlaceholderToolView(tool: .merge)
        .frame(width: 520, height: 320)
        .preferredColorScheme(.light)
}

#Preview("Placeholder – Dark") {
    PlaceholderToolView(tool: .split)
        .frame(width: 520, height: 320)
        .preferredColorScheme(.dark)
}
