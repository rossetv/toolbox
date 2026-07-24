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
    let versions: CompressViewModel.HeavyVersions
    let originalBytes: Int
    let onSwitch: () -> Void
    let onPreview: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Heavy compression").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                Text("This scan was rebuilt in compact layers. Text stays sharp, but fine background detail can soften. Both versions are ready — compare and pick.")
                    .themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                versionCard(title: "Heavy", url: heavyURL, bytes: versions.heavyBytes,
                            current: versions.shippedIsHeavy)
                versionCard(title: normalTitle, url: normalURL, bytes: versions.normalBytes,
                            current: !versions.shippedIsHeavy)
            }
            HStack {
                Spacer()
                Button(versions.shippedIsHeavy ? "Switch to \(normalTitle.lowercased())"
                                               : "Switch to heavy",
                       action: onSwitch)
                    .buttonStyle(.plain)
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

    private var heavyURL: URL { versions.shippedIsHeavy ? versions.shippedURL : versions.runnerUpURL }
    private var normalURL: URL { versions.shippedIsHeavy ? versions.runnerUpURL : versions.shippedURL }

    /// "Normal" is the losing gs compression; when gs bloated, the parked alternative is the
    /// untouched input and calling it "Normal" with a savings pill would be a lie (R6/R7).
    private var normalTitle: String { versions.runnerUpIsOriginal ? "Original" : "Normal" }

    private func versionCard(title: String, url: URL, bytes: Int, current: Bool) -> some View {
        VStack(spacing: 6) {
            Button { onPreview(url) } label: { PDFThumbnail(url: url, width: 72) }
                .buttonStyle(.plain).pointingHandCursor()
                .help("Preview this version")
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
