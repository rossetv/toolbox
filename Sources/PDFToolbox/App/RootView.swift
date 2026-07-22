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
        case .ocr, .merge, .split:
            PlaceholderToolView(tool: tool)
        }
    }
}

/// Temporary detail shown before a tool's real view is wired in.
private struct PlaceholderToolView: View {
    let tool: Tool

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(tool.isAvailable ? Theme.Colors.accent : .secondary)
            Text(tool.title)
                .font(.largeTitle.weight(.semibold))
            Text(tool.isAvailable ? "Coming together." : "Coming soon.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tool.title)
    }
}
