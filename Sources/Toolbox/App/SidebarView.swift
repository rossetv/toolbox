// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The tool sidebar: one entry per built tool under a "PDF Tools" group label, each a coloured
/// tile plus its name.
///
/// Deliberately a plain `VStack` of buttons rather than a `List` inside `NavigationSplitView`.
/// That combination laid itself out a titlebar's height too high — the first entries scrolled out
/// of view and the rest drawn over the traffic lights — which is how the app shipped looking as
/// though it had no sidebar at all. An explicit stack is fully deterministic and matches the
/// mockup's fixed-width rail exactly.
struct SidebarView: View {
    @Binding var selection: Tool?
    @Binding var isCollapsed: Bool

    @State private var isShowingAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 9) {
                    if isCollapsed {
                        ToolIconTile(systemImage: "sidebar.left",
                                     size: 22,
                                     tint: Theme.Colors.textSecondary)
                    } else {
                        // The real bundle icon, so the header always matches the Dock/Finder
                        // artwork without a duplicated asset.
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
                        Text("Toolbox").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clearsClickFocus()
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
                    selection = tool
                } label: {
                    row(for: tool)
                }
                .buttonStyle(.plain)
                .clearsClickFocus()
                .pointingHandCursor()
            }

            Spacer(minLength: 0)

            Button {
                isShowingAbout = true
            } label: {
                HStack(spacing: 9) {
                    ToolIconTile(systemImage: "info.circle",
                                 size: 22,
                                 tint: Theme.Colors.textSecondary)
                    if !isCollapsed {
                        Text("About")
                            .themeFont(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clearsClickFocus()
            .pointingHandCursor()
            .help("About Toolbox")
            .accessibilityLabel("About Toolbox")
            .padding(.horizontal, isCollapsed ? 17 : 16)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background)
        .sheet(isPresented: $isShowingAbout) { AboutView() }
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.Colors.text.opacity(0.10) : Color.clear)
        )
        // 7 collapsed, not 8: the 22pt tile plus 10pt of inner padding leaves the row 2pt wider
        // than the 56pt rail otherwise — the selection capsule overhangs it and every tool glyph
        // sits 1pt right of the header and About glyphs above and below it.
        .padding(.horizontal, isCollapsed ? 7 : 8)
        .contentShape(Rectangle())
        // The row is a bare glyph when collapsed, so the tool's name has to come from somewhere.
        .help(tool.title)
        .accessibilityLabel(tool.title)
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
