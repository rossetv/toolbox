// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import SwiftUI

/// The batch Quality popover (handoff screen 04): three presets, each priced for the actual
/// queue, with Balanced marked RECOMMENDED. Selecting a row sets the batch preset directly —
/// the same `model.preset` the Ready screen's chip suffix already shows.
struct QualityPopover: View {
    @ObservedObject var model: QueueViewModel

    var body: some View {
        PopoverChrome(width: 330) {
            VStack(spacing: 1) {
                ForEach(CompressPreset.allCases) { preset in
                    RadioRow(
                        title: preset.title,
                        subtitle: Self.subtitle(for: preset),
                        isSelected: model.preset == preset,
                        trailingValue: QueueByteFormat.string(Self.batchTotal(rows: rows, candidate: preset)),
                        badge: preset == .balanced ? "RECOMMENDED" : nil,
                        showsUnselectedIndicator: false,
                        action: { model.preset = preset }
                    )
                }
            }
            .padding(6)
        }
    }

    /// Every row's own override preset (nil = follows the batch) plus its analysis, decoupled
    /// from `ToolJob` so the pure total below is directly testable.
    private var rows: [RowInput] {
        model.jobs.map { RowInput(overridePreset: model.overrides[$0.id]?.preset,
                                  estimates: model.analysis(for: $0)?.estimates) }
    }

    struct RowInput {
        let overridePreset: CompressPreset?
        let estimates: [CompressPreset: SizeEstimate]?
    }

    /// The right-aligned total for one candidate preset, "as if the whole batch ran there" —
    /// except a row that overrides its OWN preset never moves off it (spec §6.1): the override
    /// always wins, regardless of which row the popover is asking about. A row with no analysis
    /// yet (still time-boxed) contributes nothing rather than blocking the other rows' total.
    static func batchTotal(rows: [RowInput], candidate: CompressPreset) -> Int {
        rows.reduce(0) { sum, row in
            guard let estimates = row.estimates else { return sum }
            let preset = row.overridePreset ?? candidate
            return sum + (estimates[preset]?.predictedBytes ?? 0)
        }
    }

    /// Copy verbatim from the handoff (screen 04).
    static func subtitle(for preset: CompressPreset) -> String {
        switch preset {
        case .smallestSize: return "For email limits. Photographs soften."
        case .balanced: return "Indistinguishable on screen."
        case .maximumQuality: return "Safe to print at full size."
        }
    }

}

#Preview("QualityPopover") {
    let model = QueueViewModel(engine: nil)
    return QualityPopover(model: model)
        .padding(60)
        .background(Theme.Colors.background)
}
