// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
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
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 9) {
                    ToolIconTile(systemImage: isCollapsed ? "sidebar.left" : "doc.on.doc.fill",
                                 size: 22,
                                 tint: isCollapsed ? Theme.Colors.textSecondary : Theme.Colors.accent)
                    if !isCollapsed {
                        Text("Toolbox").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
            .help(isCollapsed ? "Show sidebar" : "Hide sidebar")
            .padding(.horizontal, isCollapsed ? 17 : 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            if !isCollapsed {
                SectionLabel("PDF Tools")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }

            ForEach(Tool.allCases) { tool in
                Button {
                    guard tool.isAvailable else { return }
                    selection = tool
                } label: {
                    row(for: tool)
                }
                .buttonStyle(.plain)
                // Without this the row keeps a blue keyboard-focus ring after it is clicked, so
                // the previously-chosen tool still looks selected alongside the real selection.
                .focusEffectDisabled()
                .disabled(!tool.isAvailable)
                .pointingHandCursor()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background)
    }

    private func row(for tool: Tool) -> some View {
        let isSelected = (selection == tool)
        return HStack(spacing: 9) {
            ToolIconTile(systemImage: tool.systemImage, tint: tool.tint)
            if !isCollapsed {
                Text(tool.title)
                    .themeFont(.caption)
                    .foregroundStyle(Theme.Colors.text)
                Spacer(minLength: Theme.Spacing.small)
                if !tool.isAvailable {
                    StatPill(text: "Soon", tone: .neutral)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.Colors.text.opacity(0.10) : Color.clear)
        )
        .padding(.horizontal, 8)
        .opacity(tool.isAvailable ? 1 : 0.45)
        .contentShape(Rectangle())
        .help(isCollapsed ? tool.title : "")
    }
}

#Preview("Sidebar – Light") {
    SidebarView(selection: .constant(.compress), isCollapsed: .constant(false))
        .frame(width: 220, height: 360)
        .preferredColorScheme(.light)
}

#Preview("Sidebar – Dark") {
    SidebarView(selection: .constant(.ocr), isCollapsed: .constant(true))
        .frame(width: 220, height: 360)
        .preferredColorScheme(.dark)
}
