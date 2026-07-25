// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The capsule's popover: both versions side by side with real thumbnails and on-disk sizes;
/// one button swaps them instantly (spec R9–R11). Copy is the user-approved mock's, verbatim.
struct HeavyCompressionPopover: View {
    let versions: RowVersions
    let originalBytes: Int
    let onSwitch: () -> Void
    let onPreview: (URL) -> Void

    var body: some View {
        // This popover only ever draws for a row with both versions: `versions(for:)` returned
        // nil otherwise, and the capsule that opens it is drawn only on a `.doneHeavy` row —
        // which Task 12 derives from `row.count > 1`, i.e. exactly the rows that have a pair.
        // One unwrap here keeps the card code identical to today's.
        if let shipped = versions.shipped, let runnerUp = versions.runnerUp {
            content(shipped: shipped, runnerUp: runnerUp)
        }
    }

    @ViewBuilder
    private func content(shipped: FileVersion, runnerUp: FileVersion) -> some View {
        let shippedIsHeavy = shipped.variant == .mrc
        let heavyURL = (shippedIsHeavy ? shipped : runnerUp).url
        let normalURL = (shippedIsHeavy ? runnerUp : shipped).url
        // "Normal" is the losing gs compression; when gs bloated, the parked alternative is the
        // untouched input and calling it "Normal" with a savings pill would be a lie (R6/R7). The
        // same positional selector as `normalURL`, deliberately: the label must describe whichever
        // record currently occupies the NORMAL position, and a switch moves records between the
        // shipped and runner-up positions.
        let normalTitle = ((shippedIsHeavy ? runnerUp : shipped).variant == .original)
            ? "Original" : "Normal"
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Heavy compression").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                Text("This scan was rebuilt in compact layers. Text stays sharp, but fine background detail can soften. Both versions are ready — compare and pick.")
                    .themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                versionCard(title: "Heavy", url: heavyURL,
                            bytes: (shippedIsHeavy ? shipped : runnerUp).bytes,
                            current: shippedIsHeavy)
                versionCard(title: normalTitle, url: normalURL,
                            bytes: (shippedIsHeavy ? runnerUp : shipped).bytes,
                            current: !shippedIsHeavy)
            }
            HStack {
                Spacer()
                Button(shippedIsHeavy ? "Switch to \(normalTitle.lowercased())"
                                      : "Switch to heavy",
                       action: onSwitch)
                    .buttonStyle(.plain)
                    .clearsClickFocus()
                    .font(Theme.Typography.caption.font).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .background(Theme.Colors.accent,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func versionCard(title: String, url: URL, bytes: Int, current: Bool) -> some View {
        VStack(spacing: 6) {
            Button {
                onPreview(url)
            } label: { PDFThumbnail(url: url, width: 72) }
                .buttonStyle(.plain).clearsClickFocus().pointingHandCursor()
                .help("Preview this version")
                .accessibilityLabel("Preview the \(title) version")
            Text(title).themeFont(.microBold).foregroundStyle(Theme.Colors.text)
            HStack(spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .themeFont(.micro).foregroundStyle(Theme.Colors.textSecondary)
                // No pill on a non-saving version ("−0%" on the Original card is nonsense).
                if bytes < originalBytes {
                    StatPill(text: savedText(bytes), tone: .success)
                }
            }
            Text(current ? "Current" : " ").themeFont(.micro).foregroundStyle(Theme.Colors.link)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Theme.Colors.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(current ? Theme.Colors.accent : .clear, lineWidth: 1.5))
    }

    private func savedText(_ bytes: Int) -> String {
        "−\(Int((1 - Double(bytes) / Double(max(originalBytes, 1))) * 100))%"
    }
}
