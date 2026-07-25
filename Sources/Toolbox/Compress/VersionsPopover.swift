// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The capsule's popover: every version of a row side by side with real thumbnails and on-disk
/// sizes; any non-current card can be brought back with one click (R15). Two cards keep today's
/// 340 pt layout; a third — the previous version a recompress parked — widens it to 470 pt.
struct VersionsPopover: View {
    let versions: RowVersions
    let onUse: (VersionSlot) -> Void
    let onPreview: (URL) -> Void

    /// 340 pt for two cards (today's geometry, unchanged), 470 pt for three.
    private var width: CGFloat { versions.count > 2 ? 470 : 340 }

    private var title: String { versions.previous == nil ? "Heavy compression" : "Versions" }

    private var blurb: String {
        versions.previous == nil
            ? "This scan was rebuilt in compact layers. Text stays sharp, but fine background detail can soften. Both versions are ready — compare and pick."
            : "Every version of this file that is still on disk. Preview any of them, and bring one back with a click. Versions live until the app closes or the row is cleared."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                Text(blurb)
                    .themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                ForEach(Array(versions.cards.enumerated()), id: \.offset) { _, card in
                    versionCard(card.version, slot: card.slot)
                }
            }
        }
        .padding(16)
        .frame(width: width)
    }

    /// "Smallest · Heavy", "Smallest · Normal", "Balanced (previous)" — the preset is what the user
    /// chose and the variant is what the engine did with it, so a card names both.
    private func label(_ version: FileVersion, slot: VersionSlot?) -> String {
        if slot == .previous { return "\(version.preset.title) (previous)" }
        switch version.variant {
        case .mrc: return "\(version.preset.title) · Heavy"
        case .plain: return "\(version.preset.title) · Normal"
        case .original: return "Original"
        }
    }

    private func versionCard(_ version: FileVersion, slot: VersionSlot?) -> some View {
        VStack(spacing: 6) {
            Button {
                onPreview(version.url)
            } label: { PDFThumbnail(url: version.url, width: 72) }
                .buttonStyle(.plain).clearsClickFocus().pointingHandCursor()
                .help("Preview this version")
                .accessibilityLabel("Preview the \(label(version, slot: slot)) version")
            Text(label(version, slot: slot)).themeFont(.microBold).foregroundStyle(Theme.Colors.text)
            HStack(spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(version.bytes), countStyle: .file))
                    .themeFont(.micro).foregroundStyle(Theme.Colors.textSecondary)
                // No pill on a non-saving version ("−0%" on the Original card is nonsense).
                if version.bytes < versions.originalBytes {
                    StatPill(text: savedText(version.bytes), tone: .success)
                }
            }
            if let slot {
                Button("Use this") { onUse(slot) }
                    .buttonStyle(.plain)
                    .clearsClickFocus()
                    .font(Theme.Typography.caption.font).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.vertical, 5).padding(.horizontal, 12)
                    .background(Theme.Colors.accent,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .pointingHandCursor()
            } else {
                Text("Current").themeFont(.micro).foregroundStyle(Theme.Colors.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Theme.Colors.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(slot == nil ? Theme.Colors.accent : .clear, lineWidth: 1.5))
    }

    private func savedText(_ bytes: Int) -> String {
        "−\(Int((1 - Double(bytes) / Double(max(versions.originalBytes, 1))) * 100))%"
    }
}
