// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The tool sidebar: four fixed entries (spec §7). Live tools are selectable;
/// unavailable ones are dimmed, disabled, and badged "Soon".
struct SidebarView: View {
    @Binding var selection: Tool?

    var body: some View {
        List(selection: $selection) {
            ForEach(Tool.allCases) { tool in
                Label(tool.title, systemImage: tool.systemImage)
                    .badge(tool.isAvailable ? nil : Text("Soon"))
                    .foregroundStyle(tool.isAvailable ? Color.primary : Color.secondary)
                    .tag(tool)
                    .disabled(!tool.isAvailable)
            }
        }
        .navigationTitle("PDF Toolbox")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }
}
