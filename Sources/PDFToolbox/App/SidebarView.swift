// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The tool sidebar: four fixed entries (spec §7) under a "PDF Tools" group label, each an
/// accent tile plus its name. Live tools are selectable; unavailable ones are dimmed and badged
/// "Soon".
///
/// Deliberately a plain `VStack` of buttons rather than a `List` inside `NavigationSplitView`.
/// That combination laid itself out a titlebar's height too high — the first entries scrolled out
/// of view and the rest drawn over the traffic lights — which is how the app shipped looking as
/// though it had no sidebar at all. An explicit stack is fully deterministic and matches the
/// mockup's fixed-width rail exactly.
struct SidebarView: View {
    @Binding var selection: Tool?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("PDF Tools")
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ForEach(Tool.allCases) { tool in
                Button {
                    guard tool.isAvailable else { return }
                    selection = tool
                } label: {
                    row(for: tool)
                }
                .buttonStyle(.plain)
                .disabled(!tool.isAvailable)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background)
    }

    private func row(for tool: Tool) -> some View {
        let isSelected = (selection == tool)
        return HStack(spacing: 9) {
            ToolIconTile(systemImage: tool.systemImage)
            Text(tool.title)
                .themeFont(.caption)
                .foregroundStyle(isSelected ? Color.white : Theme.Colors.text)
            Spacer(minLength: Theme.Spacing.small)
            if !tool.isAvailable {
                StatPill(text: "Soon", tone: .neutral)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.Colors.accent : Color.clear)
        )
        .padding(.horizontal, 8)
        .opacity(tool.isAvailable ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

#Preview("Sidebar – Light") {
    SidebarView(selection: .constant(.compress))
        .frame(width: 220, height: 360)
        .preferredColorScheme(.light)
}

#Preview("Sidebar – Dark") {
    SidebarView(selection: .constant(.ocr))
        .frame(width: 220, height: 360)
        .preferredColorScheme(.dark)
}
