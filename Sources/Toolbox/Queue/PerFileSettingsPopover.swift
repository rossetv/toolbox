// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// Per-file settings (handoff screen 04c), opened from a row's gear: one row's Quality/Rebuild/
/// OCR overriding the batch (spec §6.1). Every control commits immediately through
/// `model.setOverride(_:for:)` — there is no OK/Cancel here, only "Match the batch".
struct PerFileSettingsPopover: View {
    @ObservedObject var model: QueueViewModel
    let jobID: ToolJob.ID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Right-aligned to the row's gear (README screen 04c): the tail sits near the popover's
        // trailing edge, not centred like the batch popovers above the chip.
        PopoverChrome(width: 300, tailOffset: 250) {
            if let job = model.jobs.first(where: { $0.id == jobID }) {
                content(for: job)
            }
        }
    }

    private func content(for job: ToolJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(job)
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Quality")
                SegmentedRow(options: CompressPreset.allCases.map(\.title), selection: presetIndex)
                if let caption = qualityCaption {
                    Text(caption).themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            rebuildToggle(for: job)
            ToggleRow(title: "Read the text (OCR)", stateLine: ocrStateLine, isOn: ocrBinding)
            Divider()
            HStack {
                (Text("Estimate ").themeFont(.body13)
                    + Text(estimateText(for: job)).themeFont(.body13).fontWeight(.semibold))
                    .foregroundStyle(Theme.Colors.text)
                Spacer(minLength: Theme.Spacing.small)
                LinkButton(title: "Match the batch") { model.setOverride(nil, for: jobID) }
            }
        }
        .padding(10)
    }

    private func header(_ job: ToolJob) -> some View {
        PopoverFileHeader(job: job, caption: "Overrides just this file") { dismiss() }
    }

    // MARK: rebuild-scan toggle domain (spec §7's UI half)

    /// Where the toggle stands for this row right now (spec §7, pinned): hidden off a
    /// `.scanColour` row entirely, disabled with an explanatory caption at Maximum quality (MRC
    /// D3 — never rebuilds there), enabled everywhere else a scan classification exists.
    enum RebuildToggleDomain: Equatable { case hidden; case enabled; case disabledAtMaximumQuality }

    static func rebuildToggleDomain(contentType: PDFContentType?, preset: CompressPreset) -> RebuildToggleDomain {
        guard contentType == .scanColour else { return .hidden }
        return preset == .maximumQuality ? .disabledAtMaximumQuality : .enabled
    }

    @ViewBuilder
    private func rebuildToggle(for job: ToolJob) -> some View {
        let domain = Self.rebuildToggleDomain(contentType: model.inspections[jobID]?.contentType,
                                              preset: model.effectivePreset(for: jobID))
        switch domain {
        case .hidden:
            EmptyView()
        case .enabled:
            ToggleRow(title: "Rebuild the scan", stateLine: rebuildStateLine, isOn: rebuildBinding)
        case .disabledAtMaximumQuality:
            ToggleRow(title: "Rebuild the scan",
                     stateLine: "Off — High quality never rebuilds a scan", isOn: .constant(false))
                .disabled(true)
        }
    }

    private var rebuildStateLine: String {
        (model.overrides[jobID]?.rebuildScan ?? true)
            ? "On — text traced, paper flattened"
            : "Off — stamps stay photographic"
    }

    private var rebuildBinding: Binding<Bool> {
        Binding(
            get: { model.overrides[jobID]?.rebuildScan ?? true },
            set: { newValue in setOverride { $0.rebuildScan = newValue } }
        )
    }

    // MARK: OCR toggle

    private var ocrStateLine: String {
        guard model.overrides[jobID]?.ocr ?? model.ocrOn else { return "Off" }
        let code = model.ocrOptions.languages.first
        let language = OCROptions.curatedLanguages.first { $0.code == code }?.display ?? "Automatic"
        return "\(language) · \(model.ocrOptions.accuracy.title)"
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { model.overrides[jobID]?.ocr ?? model.ocrOn },
            set: { newValue in setOverride { $0.ocr = newValue } }
        )
    }

    // MARK: quality

    private var qualityCaption: String? {
        let batch = model.preset
        let effective = model.effectivePreset(for: jobID)
        guard effective != batch else { return nil }
        return "The batch is on \(batch.title)."
    }

    private var presetIndex: Binding<Int> {
        Binding(
            get: { CompressPreset.allCases.firstIndex(of: model.effectivePreset(for: jobID)) ?? 0 },
            set: { index in setOverride { $0.preset = CompressPreset.allCases[index] } }
        )
    }

    // MARK: estimate (advisor: reuse the model's own re-priced analysis — never a second estimator)

    /// The row's own predicted size at its own effective preset — the SAME `analyse(_:mrcEligible:)`
    /// pass `QueueViewModel.setOverride` re-schedules whenever the rebuild opt-out flips, so
    /// this always reads the number the row itself would show, never a second, independently
    /// computed one.
    private func estimateText(for job: ToolJob) -> String {
        guard let bytes = model.analysis(for: job)?.estimates[model.effectivePreset(for: jobID)]?.predictedBytes else {
            return "…"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: override mutation

    /// Every control writes through here: read the row's current override (or a fresh empty one),
    /// touch only the one field this control owns, and hand the result to
    /// `model.setOverride(_:for:)` — which normalises an all-nil result back to "no override" on
    /// its own.
    private func setOverride(_ mutate: (inout RowOverride) -> Void) {
        var current = model.overrides[jobID] ?? RowOverride()
        mutate(&current)
        model.setOverride(current, for: jobID)
    }
}

/// The file-name + thumbnail + caption header row shared by the row popovers (04c, 07): a 26pt
/// thumbnail, the file name (truncating middle), a caption line, and the close button — identical
/// apart from the caption text.
struct PopoverFileHeader: View {
    let job: ToolJob
    let caption: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PDFThumbnail(url: job.url, width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.url.lastPathComponent).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(caption).themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.small)
            PopoverCloseButton(action: onClose)
        }
    }
}

/// The small circular × close affordance shared by every popover/sheet that needs one (04c, 07,
/// and the About sheet). Two real call sites differ on three things — size, fill, and which focus
/// treatment applies — so those are parameters rather than a second near-identical type: `.popover`
/// (the default) is the WindowSetup-covered main-window case and gets `.clearsClickFocus()`;
/// `.about` is the one carve-out DESIGN.md §6 already blesses for a window outside that net
/// (memory: stray-focus-ring invariant) and gets `.focusEffectDisabled()` instead.
struct PopoverCloseButton: View {
    enum Style: Equatable {
        /// 20pt/9pt glyph, `Theme.Colors.fill`/`track` — the popover chrome's own hover tokens.
        case popover
        /// 24pt/10pt glyph, `Theme.Colors.text` at low/high opacity — the About sheet's own look.
        case about
    }

    let action: () -> Void
    var style: Style = .popover

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var diameter: CGFloat { style == .about ? 24 : 20 }
    private var glyphSize: CGFloat { style == .about ? 10 : 9 }

    private var fill: Color {
        switch style {
        case .about: return Theme.Colors.text.opacity(isHovering ? 0.32 : 0.08)
        case .popover: return isHovering ? Theme.Colors.track : Theme.Colors.fill
        }
    }

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(isHovering ? Theme.Colors.text : Theme.Colors.textSecondary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(MotionButtonStyle())
        .pointingHandCursor()
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .continuousHover($isHovering)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityLabel("Close")

        switch style {
        case .about: button.focusEffectDisabled()
        case .popover: button.clearsClickFocus()
        }
    }
}

#Preview("PerFileSettingsPopover") {
    let model = QueueViewModel(engine: nil)
    return Color.clear.frame(width: 1, height: 1)
        .background(Theme.Colors.background)
        .frame(width: 400, height: 400)
        .overlay(alignment: .topLeading) {
            if let job = model.jobs.first {
                PerFileSettingsPopover(model: model, jobID: job.id)
            }
        }
}
