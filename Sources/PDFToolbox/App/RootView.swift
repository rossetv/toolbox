// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The shell: a sidebar of tools beside the selected tool's detail view.
struct RootView: View {
    @State private var selectedTool: Tool? = .compress

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedTool)
        } detail: {
            detail(for: selectedTool ?? .compress)
        }
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
