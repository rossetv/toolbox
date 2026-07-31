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
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: hoverLocation == nil)
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
                        title: "\(batch.fileCount) file\(batch.fileCount == 1 ? "" : "s") in \(batch.folderName)",
                        subtitle: subtitle(for: batch),
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

    /// `HistoryBatch` records only aggregate flags (`problem`/`partial`/`cancelled`), never a
    /// per-row success count or a specific failure reason — so the handoff's literal "4 of 5
    /// files… one was password-locked" cannot be reproduced faithfully from what the store
    /// holds. This composes the closest honest line from the fields that exist (recorded
    /// divergence, P-A; a richer HistoryBatch would need a foundation-owned change to F6/
    /// `HistoryStore.swift`, outside this track's files).
    private func subtitle(for batch: HistoryBatch) -> String {
        let time = batch.date.formatted(date: .omitted, time: .shortened)
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
