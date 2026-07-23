// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The tool sidebar: four fixed entries (spec §7) under a "PDF Tools" group label, each an
/// accent tile plus its name. Live tools are selectable; unavailable ones are dimmed, disabled,
/// and badged "Soon".
struct SidebarView: View {
    @Binding var selection: Tool?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Tool.allCases) { tool in
                    row(for: tool)
                        .tag(tool)
                        .disabled(!tool.isAvailable)
                }
            } header: {
                SectionLabel("PDF Tools")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PDF Toolbox")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    /// Row text takes no explicit colour: the selected row's fill is drawn by AppKit, which
    /// flips the label to white on top of it. Hard-coding `Theme.Colors.text` here would leave
    /// near-black text on the blue selection.
    private func row(for tool: Tool) -> some View {
        HStack(spacing: 9) {
            ToolIconTile(systemImage: tool.systemImage)
            Text(tool.title).themeFont(.caption)
            Spacer(minLength: Theme.Spacing.small)
            if !tool.isAvailable {
                StatPill(text: "Soon", tone: .neutral)
            }
        }
        .padding(.vertical, 2)
        .opacity(tool.isAvailable ? 1 : 0.45)
    }
}

#Preview("Sidebar – Light") {
    SidebarView(selection: .constant(.compress))
        .frame(width: 220, height: 320)
        .preferredColorScheme(.light)
}

#Preview("Sidebar – Dark") {
    SidebarView(selection: .constant(.ocr))
        .frame(width: 220, height: 320)
        .preferredColorScheme(.dark)
}
