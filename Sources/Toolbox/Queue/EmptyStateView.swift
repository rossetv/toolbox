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
    /// A drag is over the window, so `DragOverlayView` is drawing its own icon, headline and
    /// subtitle in the middle of this same area — the centred stack below hides rather than
    /// showing through it. The history strip stays: nothing overlaps it.
    var isDropTargeted: Bool = false
    let onChooseFiles: () -> Void

    /// Pointer position normalised to ±1 from the centre of the whole centred content area (the
    /// handoff's `[data-parallax-stage]`), `nil` while the pointer is away — written by
    /// `parallaxStage(_:)`, which also owns the Reduce Motion gate.
    @State private var pointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            stage

            if !history.batches.isEmpty {
                Divider()
                historyStrip
            }
        }
        .background(Theme.Colors.surface)
    }

    private var stage: some View {
        VStack(spacing: 18) {
            ParallaxAppIcon(pointer: pointer)
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
            Label {
                Text("Nothing leaves this Mac").themeFont(.micro)
            } icon: {
                Image(systemName: "lock.fill").font(.system(size: 10))
            }
            .foregroundStyle(Theme.Colors.textTertiary)
        }
        .opacity(isDropTargeted ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The stage is the whole centred area, not the icon: the icon leans towards the pointer
        // wherever it is in this half of the window (DESIGN.md §8).
        .parallaxStage($pointer)
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

    /// "14:22 · Smallest · one was password-locked" for a batch with a problem row (screen 01,
    /// `failureNote`) — the quality segment rides alongside the note rather than being replaced
    /// by it, matching `RecentBatchesSheet.subtitle`'s composition. "14:22 · 21.2 MB smaller" for
    /// a clean run. Falls back to a generic line only for a batch recorded before `failureNote`
    /// existed (an older on-disk schema).
    static func subtitle(for batch: HistoryBatch) -> String {
        var parts = [batch.date.formatted(date: .omitted, time: .shortened)]
        if batch.compressOn, let preset = batch.presetTitle {
            parts.append(preset)
        } else if batch.ocrOn {
            parts.append("OCR only")
        }
        if let note = batch.failureNote {
            parts.append(note)
        } else if batch.problem {
            parts.append("needs attention")
        } else if batch.savedBytes > 0 {
            parts.append("\(QueueByteFormat.string(batch.savedBytes)) smaller")
        } else if batch.searchableCount > 0 {
            parts.append("made searchable")
        } else {
            parts.append("no change")
        }
        return parts.joined(separator: " · ")
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
