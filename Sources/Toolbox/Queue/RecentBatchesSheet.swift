// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The Recent-batches sheet (handoff screen 11), opened from the `⋯` menu: every batch grouped
/// by day, newest first, with the lifetime saving total. "Clear list" empties the list only —
/// `lifetimeSavedBytes` survives (spec §6.9), matching the footer's own promise.
struct RecentBatchesSheet: View {
    @ObservedObject var history: HistoryStore
    /// Presented as an in-window overlay (see `QueueView`'s overlay call site), so closing is a
    /// caller-supplied closure — `@Environment(\.dismiss)` has no presentation to dismiss here.
    let onClose: () -> Void

    var body: some View {
        SheetChrome(width: 520) {
            VStack(alignment: .leading, spacing: 14) {
                SheetTitleRow(title: "Recent batches",
                             caption: "\(QueueByteFormat.string(history.lifetimeSavedBytes)) saved in total")
                if history.groupedByDay.isEmpty {
                    Text("No batches yet.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(history.groupedByDay, id: \.day) { group in
                                SectionLabel(Self.dayLabel(group.day))
                                VStack(spacing: 2) {
                                    ForEach(group.batches) { batch in
                                        BatchCard(
                                            icon: batch.problem ? .warn : .finished,
                                            title: Self.title(for: batch),
                                            subtitle: Self.subtitle(for: batch),
                                            trailingValue: (text: Self.savedText(batch),
                                                           isMuted: batch.savedBytes <= 0),
                                            action: { NSWorkspace.shared.open(batch.folderURL) })
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                Divider()
                HStack {
                    Text("Kept on this Mac. Clearing it doesn't delete any files.")
                        .themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
                    Spacer(minLength: Theme.Spacing.small)
                    LinkButton(title: "Clear list") { history.clearList() }
                    PrimaryButton(title: "Done", action: onClose)
                }
            }
            .padding(20)
        }
    }

    // MARK: pure logic (PopoverLogicTests)

    static func title(for batch: HistoryBatch) -> String {
        batch.displayTitle
    }

    /// "14:22 · Balanced · one made searchable" for a clean run; "11:05 · Smallest · one was
    /// password-locked" for a batch with a problem row (screen 11, `failureNote`) — falls
    /// back to a generic clause only for a batch recorded before `failureNote` existed (an
    /// older on-disk schema).
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
            parts.append("some files needed attention")
        } else if batch.searchableCount > 0 {
            if batch.searchableCount == batch.fileCount {
                parts.append("all searchable")
            } else if batch.searchableCount == 1 {
                parts.append("one made searchable")
            } else {
                parts.append("\(batch.searchableCount) made searchable")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The trailing figure: green savings, or grey "no change" for an OCR-only/no-saving batch
    /// (OCR-only reads grey, never a bare "0 MB").
    static func savedText(_ batch: HistoryBatch) -> String {
        batch.savedBytes <= 0 ? "no change" : QueueByteFormat.string(batch.savedBytes)
    }

    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "YESTERDAY"
        }
        return Self.dateFormatter.string(from: day).uppercased()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

}

#Preview("RecentBatchesSheet") {
    RecentBatchesSheet(history: HistoryStore(directory: FileManager.default.temporaryDirectory), onClose: {})
        .frame(width: 700, height: 600)
        .background(Theme.Colors.background)
}
