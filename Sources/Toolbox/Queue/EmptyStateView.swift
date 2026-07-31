// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// Screen 01 — first run / idle. Centred icon (with pointer parallax) + headline + Choose
/// Files… + a "nothing leaves this Mac" reassurance, with the two most recent batches (if any)
/// in a strip along the bottom.
struct EmptyStateView: View {
    @ObservedObject var history: HistoryStore
    let onChooseFiles: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverLocation: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                icon
                VStack(spacing: 4) {
                    // No exact `Theme.Typography` case matches the handoff's 26/600 (the
                    // closest incumbents are `tileHeading` 28/regular and `windowHeadline`
                    // 22/600) — an inline literal, matching `QueueComponents`' own precedent
                    // for one-off sizes with no token.
                    Text("Drop PDFs to begin")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Colors.text)
                    Text("Compress them, OCR them, or both.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                PrimaryButton(title: "Choose Files…", action: onChooseFiles)
                    .padding(.top, 4)
                Label {
                    Text("Nothing leaves this Mac").themeFont(.micro)
                } icon: {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                }
                .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !reduceMotion else { return }
                switch phase {
                case .active(let location):
                    // ~90ms follow (spec §8) — near-immediate, not the exit-only settle spring.
                    withAnimation(.easeOut(duration: 0.09)) { hoverLocation = location }
                case .ended:
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { hoverLocation = nil }
                }
            }

            if !history.batches.isEmpty {
                Divider()
                historyStrip
            }
        }
        .background(Theme.Colors.surface)
    }

    /// Real app icon (matches `AboutView`'s own `NSApp.applicationIconImage` source), tilting
    /// towards the pointer while it crosses the content area (spec §9: static under Reduce
    /// Motion).
    private var icon: some View {
        GeometryReader { geo in
            let tilt = parallaxTilt(in: geo.size)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .rotation3DEffect(.degrees(tilt.x), axis: (x: 0, y: 1, z: 0))
                .rotation3DEffect(.degrees(tilt.y), axis: (x: 1, y: 0, z: 0))
                .scaleEffect(hoverLocation != nil && !reduceMotion ? 1.05 : 1)
                .offset(x: tilt.x * 0.6, y: tilt.y * 0.6)
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: 76, height: 76)
        // Decorative: the headline right below it already says "Drop PDFs to begin" — VoiceOver
        // gains nothing from a second announcement of the app icon.
        .accessibilityHidden(true)
    }

    /// ±11°/±13° per the handoff, driven by the pointer's offset from the content area's centre.
    private func parallaxTilt(in size: CGSize) -> (x: Double, y: Double) {
        guard !reduceMotion, let hoverLocation, size.width > 0, size.height > 0 else { return (0, 0) }
        let dx = (hoverLocation.x / size.width) - 0.5
        let dy = (hoverLocation.y / size.height) - 0.5
        return (x: dx * 22, y: dy * -26)
    }

    // MARK: history strip

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(recentBatches.contains { Calendar.current.isDateInToday($0.date) }
                             ? "Earlier Today" : "Recent")
                Spacer(minLength: Theme.Spacing.small)
                Text("\(QueueByteFormat.string(history.lifetimeSavedBytes)) saved since you installed Toolbox")
                    .themeFont(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            HStack(spacing: 10) {
                ForEach(recentBatches) { batch in
                    BatchCard(
                        icon: batch.problem ? .warn : .finished,
                        title: batch.displayTitle,
                        subtitle: Self.subtitle(for: batch),
                        trailingLink: (title: "Open folder", action: { openFolder(batch) }),
                        action: { openFolder(batch) }
                    )
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, 14)
    }

    private var recentBatches: [HistoryBatch] { Array(history.batches.prefix(2)) }

    /// "14:22 · 21.2 MB smaller" for a clean run; "11:05 · one was password-locked" for a batch
    /// with a problem row (screen 01, F6b's `failureNote`) — falls back to a generic line only for
    /// a batch recorded before `failureNote` existed (on-disk schema predates F6b).
    static func subtitle(for batch: HistoryBatch) -> String {
        let time = batch.date.formatted(date: .omitted, time: .shortened)
        if let note = batch.failureNote { return "\(time) · \(note)" }
        if batch.problem { return "\(time) · needs attention" }
        if batch.savedBytes > 0 { return "\(time) · \(QueueByteFormat.string(batch.savedBytes)) smaller" }
        if batch.searchableCount > 0 { return "\(time) · made searchable" }
        return "\(time) · no change"
    }

    private func openFolder(_ batch: HistoryBatch) {
        NSWorkspace.shared.activateFileViewerSelecting([batch.folderURL])
    }
}

#Preview("Empty – no history") {
    EmptyStateView(history: HistoryStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-preview-\(UUID().uuidString)")), onChooseFiles: {})
        .frame(width: 900, height: 640)
}
