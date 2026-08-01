// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The versions popover (handoff screen 07), opened from a finished row's "N versions" capsule:
/// up to four radio rows — the file in use, this run's alternative, a previous recompress, and
/// the untouched original — any of which can be switched to with one tap. Replaces the legacy
/// `Compress/VersionsPopover.swift`, since deleted along with its only consumer, `CompressView`.
struct VersionsPopoverContent: View {
    @ObservedObject var model: QueueViewModel
    let jobID: ToolJob.ID
    @Environment(\.dismiss) private var dismiss

    @State private var highlighted: VersionCardKey?

    var body: some View {
        Group {
            // Both lookups are live, not cached at open time: a queued consent can be withdrawn
            // and a switch failure can clear `versions(for:)` while this popover is open — render
            // nothing rather than describe a row that no longer backs its own versions.
            if let job = model.jobs.first(where: { $0.id == jobID }),
               let row = model.versions(for: job) {
                content(job: job, row: row)
            }
        }
    }

    private func content(job: ToolJob, row: RowVersions) -> some View {
        let cards = row.cards
        return PopoverChrome(width: cards.count > 3 ? 340 : 312) {
            VStack(alignment: .leading, spacing: 12) {
                header(job: job)
                VStack(spacing: 1) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        RadioRow(
                            title: Self.cardTitle(bytes: card.version.bytes, variant: card.version.variant),
                            subtitle: Self.composedSubtitle(
                                base: Self.cardDescription(variant: card.version.variant,
                                                           isShipped: card.key == .shipped),
                                searchable: row.searchableByCard[card.key]),
                            isSelected: card.key == .shipped,
                            subtitleTone: card.key == .shipped ? .accent : .plain,
                            action: {
                                highlighted = card.key
                                Task { await model.useCard(card.key, for: job) }
                            }
                        )
                        .continuousHover { hovering in if hovering { highlighted = card.key } }
                    }
                }
                SecondaryButton(title: "Compare versions…") { compareVersions(cards: cards) }
                    .frame(maxWidth: .infinity)
                    .disabled(Self.compareVersionsPair(cards: cards, highlighted: highlighted) == nil)
            }
            .padding(10)
        }
    }

    private func header(job: ToolJob) -> some View {
        PopoverFileHeader(job: job, caption: "Switch any time before you quit") { dismiss() }
    }

    private func compareVersions(cards: [(key: VersionCardKey, version: FileVersion)]) {
        guard let pair = Self.compareVersionsPair(cards: cards, highlighted: highlighted) else { return }
        NSWorkspace.shared.open(pair.0)
        NSWorkspace.shared.open(pair.1)
    }

    // MARK: pure logic (PopoverLogicTests)

    /// "Rebuilt · 4.1 MB" / "Photographs · 6.8 MB" / "Original · 18.7 MB" — the card's generic
    /// name is keyed to what the FILE actually is, not which slot holds it, so a `previous` card
    /// reads the same name a `runnerUp` card of the same variant would.
    static func cardTitle(bytes: Int, variant: EngineVariant) -> String {
        let name: String
        switch variant {
        case .mrc: name = "Rebuilt"
        case .plain: name = "Photographs"
        case .original: name = "Original"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(name) · \(size)"
    }

    /// The row's fixed per-variant meaning, verbatim from the handoff (screen 07) for the two
    /// variants it shows; the shipped/in-use card is prefixed "In use.".
    static func cardDescription(variant: EngineVariant, isShipped: Bool) -> String {
        let base: String
        switch variant {
        case .mrc: base = "Text sharp, paper texture smoothed."
        case .plain: base = "Pages untouched, only lighter."
        case .original: base = "Never modified, still in its folder."
        }
        return isShipped ? "In use. \(base)" : base
    }

    /// Composes the honest searchability suffix (spec §6.4, this task's own recorded divergence):
    /// the fixed subtitle drops its terminal full stop and appends the claim with the handoff's
    /// own separator register. `nil` (OCR never ran for this card) leaves the design copy
    /// completely untouched, full stop and all.
    static func composedSubtitle(base: String, searchable: Bool?) -> String {
        guard let searchable else { return base }
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return trimmed + (searchable ? " · Searchable" : " · Not searchable")
    }

    /// "Compare versions…"'s pair (spec §7): the in-use version plus whichever row is currently
    /// highlighted — highlighting the in-use row itself falls back to the first parked version.
    /// `nil` when there is nothing to compare (no shipped card, or only one card at all).
    static func compareVersionsPair(cards: [(key: VersionCardKey, version: FileVersion)],
                                    highlighted: VersionCardKey?) -> (URL, URL)? {
        guard cards.count > 1, let shipped = cards.first(where: { $0.key == .shipped })?.version else {
            return nil
        }
        let parked = cards.filter { $0.key != .shipped }
        guard let firstParked = parked.first?.version else { return nil }
        guard let highlighted, highlighted != .shipped,
              let target = cards.first(where: { $0.key == highlighted })?.version else {
            return (shipped.url, firstParked.url)
        }
        return (shipped.url, target.url)
    }
}

#Preview("VersionsPopoverContent") {
    let model = QueueViewModel(engine: nil)
    return Color.clear
        .frame(width: 400, height: 400)
        .background(Theme.Colors.background)
        .overlay(alignment: .topLeading) {
            if let job = model.jobs.first {
                VersionsPopoverContent(model: model, jobID: job.id)
            }
        }
}
