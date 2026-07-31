// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// Screen 02 — drag-over. A full-bleed overlay `QueueView` shows atop WHATEVER screen is
/// currently underneath (spec §6.5/§7: every screen accepts drops, including mid-run) — the
/// handoff's one render happens to capture it over the empty state, but the content beneath is
/// deliberately not this view's concern.
struct DragOverlayView: View {
    /// Mirrors the drag's item count (README: "1 page, 2, 3, or 3 + '+N' capsule badge").
    let fileCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @State private var hasEntered = false
    @State private var floatPhase = false

    private var visiblePages: Int { min(3, max(1, fileCount)) }
    private var overflow: Int { max(0, fileCount - 3) }
    private static let restTilts: [Double] = [-9, 3, 12]

    var body: some View {
        ZStack {
            Theme.Colors.accent.opacity(0.05)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(Theme.Colors.accent.opacity(isPulsing || reduceMotion ? 1 : 0.55))
                .padding(12)
            VStack(spacing: 18) {
                pageFan
                VStack(spacing: 4) {
                    Text("Drop \(fileCount) PDF\(fileCount == 1 ? "" : "s")")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Nothing runs until you press Start.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop \(fileCount) PDF\(fileCount == 1 ? "" : "s"). Nothing runs until you press Start.")
        .onAppear {
            guard !reduceMotion else { hasEntered = true; return }
            withAnimation(.easeOut(duration: 0.5)) { hasEntered = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { isPulsing = true }
            withAnimation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true)) { floatPhase = true }
        }
    }

    private var pageFan: some View {
        ZStack {
            ForEach(0..<visiblePages, id: \.self) { index in
                mockPage
                    .rotationEffect(.degrees(Self.restTilts[index % Self.restTilts.count]))
                    .offset(x: CGFloat(index - 1) * 14,
                            y: reduceMotion || !floatPhase ? 0 : CGFloat([-1, 1, -1][index % 3]) * 8)
                    .offset(y: hasEntered || reduceMotion ? 0 : 45)
                    .opacity(hasEntered || reduceMotion ? 1 : 0)
                    .animation(reduceMotion ? nil
                               : .easeOut(duration: 0.5).delay(Double(index) * 0.07), value: hasEntered)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Colors.stroke, lineWidth: 1))
                    .offset(x: 44, y: -30)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 6)
    }

    /// A generic page mock (no real thumbnail exists yet — the drag has not delivered file URLs,
    /// only a provider count) — a plain page with `PDFThumbnail`'s red band language.
    private var mockPage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black.opacity(0.1))
                        .frame(height: 3)
                }
            }
            .padding(8)
            .frame(width: 46, height: 46, alignment: .top)
            Rectangle().fill(Theme.Colors.documentBadge).frame(width: 46, height: 10)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

#Preview("Drag-over – 1/2/3/6 files") {
    HStack(spacing: 0) {
        ForEach([1, 2, 3, 6], id: \.self) { count in
            DragOverlayView(fileCount: count).frame(width: 240, height: 300)
        }
    }
}
