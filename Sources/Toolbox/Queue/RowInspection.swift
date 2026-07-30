// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// One row's overrides of the batch settings (spec §6.1, design screen 04c). Sparse on purpose —
/// an absent field means "match the batch", and clearing every field is what the popover's
/// "Match the batch" link does.
///
/// There is deliberately **no `compress` field**: screen 04c offers exactly three controls
/// (Quality, Rebuild the scan, Read the text), so the Compress verb is batch-level only. That is
/// also why `QueueViewModel.effectiveVerbs(for:)` needs a floor on one side only — `ocr` is the
/// single verb a row can turn off, and it may not turn off the row's last one.
struct RowOverride: Equatable {
    var preset: CompressPreset?
    /// The MRC rebuild opt-out/in. `false` also releases the row's runner-up reservation: a row
    /// that will not be rebuilt can never retain a second variant.
    var rebuildScan: Bool?
    var ocr: Bool?

    init(preset: CompressPreset? = nil, rebuildScan: Bool? = nil, ocr: Bool? = nil) {
        self.preset = preset
        self.rebuildScan = rebuildScan
        self.ocr = ocr
    }

    /// True when the row overrides nothing — the state "Match the batch" restores, and the one
    /// this type stores as an absent entry rather than an empty one.
    var isEmpty: Bool { self == RowOverride() }
}

/// What add-time inspection learned about one file (spec §6.6): enough to render the Ready
/// screen's meta line, and to keep a file nothing can be done with out of the run.
///
/// Filled in two passes, because its inputs arrive at different times: `OpenGuard.inspect` and the
/// text-layer sample resolve promptly off the main actor, while `contentType` comes from the
/// time-boxed estimator analysis and can legitimately never arrive (spec §6.7). `metaLine` is
/// computed rather than stored so it can never disagree with the facts it is derived from.
struct RowInspection: Equatable {
    var pageCount: Int?
    var hasTextLayer: Bool?
    var contentType: PDFContentType?
    /// Why this file cannot be worked on. `nil` for a healthy row; never `.compressFailed`, which
    /// is a RUN outcome (spec §6.5's rescue), not something an unopened file can exhibit.
    var problem: RowProblem?

    /// The Ready screen's one-line description of the file — or, on a problem row, the condition
    /// itself (design screen 10 puts the condition in the same slot).
    ///
    /// Copy is the handoff's except where it has none: `.unreadable` has no handoff string (screen
    /// 10 names only the password and moved-file conditions) and neither does the page-count-only
    /// degradation, so both are recorded divergences owned by this task.
    var metaLine: String {
        switch problem {
        case .locked: return "Needs a password to open"
        case .missing: return "Moved or renamed since you added it"
        case .unreadable: return "This file can't be read as a PDF"
        // Unreachable from inspection — a compress failure is a run outcome. Naming it here would
        // poach the rescue's own copy, so this degrades to the file's plain description instead.
        case .compressFailed, .none: break
        }
        guard let pageCount else { return "" }
        let pages = "\(pageCount) page\(pageCount == 1 ? "" : "s")"
        guard let descriptor = contentDescriptor else { return pages }
        return "\(pages), \(descriptor)"
    }

    /// The three descriptions the handoff's Ready screen shows, mapped onto the facts that
    /// distinguish them. Searchability wins over composition on a scan: "no text layer yet" is the
    /// actionable half (it is what the OCR verb is for), while "mostly photographs" describes a
    /// scan that already reads.
    private var contentDescriptor: String? {
        if contentType == .bornDigital { return "text and vectors" }
        if hasTextLayer == false { return "no text layer yet" }
        switch contentType {
        case .scanColour, .scanBilevel, .mixedColour: return "mostly photographs"
        case .bornDigital, nil: return nil
        }
    }
}
