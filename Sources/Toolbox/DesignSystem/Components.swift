// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import PDFKit
import SwiftUI

/// Reusable components built on `Theme`, rebuilt from the Claude Design mockup
/// (kept outside this repository) — matching its feel, not its pixels.
/// Presentation-only: none of these depend on `ToolJob`/`CompressPreset`/view-model state, so
/// they stay reusable across Compress, OCR and future tools. Application to the real views
/// (`CompressView`, `OCRView`, `RootView`, `SidebarView`) is the S.1 polish pass, not this task.

// MARK: - PrimaryButton

/// The primary call-to-action. Filled with `Theme.Colors.accent`, white label, disabled/hover
/// states.
///
/// Radius is DESIGN.md §4's 8px "Primary Blue (CTA)" button, not the 980px pill: the pill
/// radius is reserved for *link* CTAs ("Learn more"/"Shop") and compact badges, and the Claude
/// Design mockup draws both of its primary actions ("Choose Files…", "Compress N PDFs") as
/// small-radius buttons too. The design system's earlier pill reading of "CTA radius" was the
/// wrong half of §4.
struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .themeFont(.button)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 22)
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x0A84FF), Theme.Colors.accent],
                startPoint: .top, endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
        .shadow(color: Theme.Colors.accent.opacity(isEnabled ? 0.35 : 0), radius: 4, x: 0, y: 2)
        .opacity(isEnabled ? (isHovering ? 0.9 : 1) : 0.4)
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        // Only offer the "clickable" cursor when the button can actually be pressed — a hand
        // over a disabled control promises something that will not happen.
        .modifier(HandCursorWhen(isEnabled: isEnabled))
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

#Preview("PrimaryButton – Light") {
    PrimaryButton(title: "Compress 3 PDFs") {}
        .padding(40)
        .background(Theme.Colors.surface)
        .preferredColorScheme(.light)
}

#Preview("PrimaryButton – Dark") {
    VStack(spacing: 16) {
        PrimaryButton(title: "Compress 3 PDFs") {}
        PrimaryButton(title: "Disabled", isEnabled: false) {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - LinkButton

/// A borderless text action in DESIGN.md's link blue — the mockup's "+ Add", "Clear",
/// "Change…" affordances. Secondary to `PrimaryButton`: no fill, no border, just the link.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .themeFont(.link)
                .foregroundStyle(Theme.Colors.link)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

#Preview("LinkButton – Light") {
    HStack(spacing: 14) {
        LinkButton(title: "+ Add") {}
        LinkButton(title: "Clear finished") {}
        LinkButton(title: "Change…") {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.light)
}

#Preview("LinkButton – Dark") {
    HStack(spacing: 14) {
        LinkButton(title: "+ Add") {}
        LinkButton(title: "Clear finished") {}
        LinkButton(title: "Change…") {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - Card

/// A flat, borderless container on `Theme.Colors.surface` (DESIGN.md §4: "no border, ...
/// elevation comes from background color contrast"). Set `elevated` to opt into the one soft
/// DESIGN.md shadow for a container that genuinely needs to lift off the page — most don't.
struct Card<Content: View>: View {
    var elevated: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.medium)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(
                color: elevated ? Theme.Shadow.color : .clear,
                radius: elevated ? Theme.Shadow.radius : 0,
                x: elevated ? Theme.Shadow.x : 0,
                y: elevated ? Theme.Shadow.y : 0
            )
    }
}

#Preview("Card – Light") {
    Card {
        VStack(alignment: .leading, spacing: 6) {
            Text("Balanced").themeFont(.cardTitle).foregroundStyle(Theme.Colors.text)
            Text("Great size, near-original look.").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
    }
    .padding(40)
    .background(Theme.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Card – Dark") {
    Card(elevated: true) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Balanced").themeFont(.cardTitle).foregroundStyle(Theme.Colors.text)
            Text("Great size, near-original look.").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
    }
    .padding(40)
    .background(Theme.Colors.background)
    .preferredColorScheme(.dark)
}

// MARK: - DropZone

/// The empty-state drag target. `isTargeted` is driven by the consuming view's own
/// `.onDrop(..., isTargeted:)` binding — this component is purely presentational.
struct DropZone: View {
    var isTargeted: Bool = false
    var title: String = "Drop PDFs here"
    var subtitle: String = "or add them manually · batch supported"
    var buttonTitle: String = "Choose Files…"
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.surface)
                    .frame(width: 66, height: 66)
                    // The disc is `surface`, and so is the pane it sits on — in dark mode the
                    // shadow alone doesn't separate them. The hairline accent ring is the
                    // mockup's own inset border and is what makes the disc read in both modes.
                    .overlay(Circle().strokeBorder(Theme.Colors.accent.opacity(0.22), lineWidth: 1))
                    .shadow(color: Theme.Colors.accent.opacity(0.18), radius: 10, x: 0, y: 6)
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
            }
            VStack(spacing: 4) {
                Text(title).themeFont(.tileHeading).foregroundStyle(Theme.Colors.text)
                Text(subtitle).themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            PrimaryButton(title: buttonTitle, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.accent.opacity(isTargeted ? 0.08 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

#Preview("DropZone – Light") {
    DropZone(action: {})
        .frame(width: 480, height: 280)
        .padding(24)
        .background(Theme.Colors.surface)
        .preferredColorScheme(.light)
}

#Preview("DropZone – Dark (hover)") {
    DropZone(isTargeted: true, action: {})
        .frame(width: 480, height: 280)
        .padding(24)
        .background(Theme.Colors.surface)
        .preferredColorScheme(.dark)
}

// MARK: - StatPill

/// A small rounded badge for a short stat, e.g. a "−74%" size-reduction figure (DESIGN.md's
/// 980px pill radius applied to a compact label rather than a button).
struct StatPill: View {
    enum Tone {
        case success, neutral, accent

        var color: Color {
            switch self {
            case .success: return Theme.Colors.success
            case .neutral: return Theme.Colors.textTertiary
            case .accent: return Theme.Colors.accent
            }
        }
    }

    let text: String
    var tone: Tone = .success

    var body: some View {
        Text(text)
            .themeFont(.microBold)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
    }
}

#Preview("StatPill – Light") {
    HStack(spacing: 8) {
        StatPill(text: "−74%")
        StatPill(text: "Queued", tone: .neutral)
        StatPill(text: "New", tone: .accent)
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.light)
}

#Preview("StatPill – Dark") {
    HStack(spacing: 8) {
        StatPill(text: "−74%")
        StatPill(text: "Queued", tone: .neutral)
        StatPill(text: "New", tone: .accent)
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - SegmentedPreset

/// One option in a `SegmentedPreset` — a title, one-line descriptor and a short hint (DESIGN.md's
/// card-vs-segmented preset picker; `id` deliberately matches `CompressPreset.id`'s `String` type
/// so the S.1 polish pass can map `CompressPreset.allCases` straight across).
struct SegmentedPresetOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let hint: String
}

/// The 3-way quality preset selector. Selection reads as an inset accent ring (DESIGN.md: no
/// borders on cards, so selection is communicated by an accent stroke + tint, not a frame).
struct SegmentedPreset: View {
    let options: [SegmentedPresetOption]
    @Binding var selection: String
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(options) { option in
                optionCard(option)
            }
        }
    }

    private func optionCard(_ option: SegmentedPresetOption) -> some View {
        let isSelected = option.id == selection
        return VStack(alignment: .leading, spacing: 4) {
            Text(option.title).themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
            Text(option.subtitle)
                .themeFont(.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(option.hint).themeFont(.nano).foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.small + 4)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.Colors.accent : Theme.Colors.textTertiary.opacity(0.35),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { selection = option.id } }
        .opacity(isEnabled ? 1 : 0.5)
        .pointingHandCursor()
    }
}

private let previewPresetOptions = [
    SegmentedPresetOption(id: "smallest", title: "Smallest", subtitle: "Maximum shrink for email & upload.", hint: "~96 DPI images"),
    SegmentedPresetOption(id: "balanced", title: "Balanced", subtitle: "Great size, near-original look.", hint: "~150 DPI images"),
    SegmentedPresetOption(id: "high", title: "High quality", subtitle: "Light touch, keeps fine detail.", hint: "~225 DPI images"),
]

#Preview("SegmentedPreset – Light") {
    SegmentedPreset(options: previewPresetOptions, selection: .constant("balanced"))
        .padding(40)
        .background(Theme.Colors.background)
        .preferredColorScheme(.light)
}

#Preview("SegmentedPreset – Dark") {
    SegmentedPreset(options: previewPresetOptions, selection: .constant("smallest"))
        .padding(40)
        .background(Theme.Colors.background)
        .preferredColorScheme(.dark)
}

// MARK: - FileRow

/// One file in a batch queue (DESIGN.md handover §5 "File-queue row"). Covers every state
/// `JobState`/`JobOutcome` can reach in either tool — inline, so a failing file in a batch
/// doesn't disrupt the rest of the list. Purely presentational: the consuming view maps its
/// job state onto a `Status` and supplies any wording that varies by tool.
struct FileRow: View {
    enum Status {
        /// Waiting to start. `detail` is the trailing note — Compress puts its size estimate
        /// there, OCR (which has nothing to predict) just says "Queued".
        case queued(detail: String?, savedPercent: Int?)
        /// Pre-flight analysis in flight (Compress's per-file size estimate).
        case analysing
        case inProgress(fraction: Double?)
        /// Finished with a real size delta: original → new, plus a saved-percentage pill.
        case done(originalBytes: Int, newBytes: Int)
        /// Finished with a real size delta, plus a capsule offering heavier re-compression.
        case doneHeavy(originalBytes: Int, newBytes: Int)
        /// Finished with a message rather than a size delta (OCR's "Searchable — 12 pages").
        case succeeded(String)
        /// Finished with nothing to do — "Already optimised" / "Already searchable".
        case unchanged(String)
        case error(String)
    }

    let name: String
    let meta: String
    /// The file this row represents, used to draw a preview of its first page. Nil falls back to
    /// a plain document mark, which is what the previews and any non-file row get.
    var fileURL: URL?
    var status: Status = .queued(detail: nil, savedPercent: nil)
    var onRemove: (() -> Void)?
    /// Opening the file the row represents. Nil leaves the row inert.
    var onOpen: (() -> Void)?
    /// Opening the heavy-compression options for this file. Nil leaves the capsule inert.
    var onHeavyTap: (() -> Void)?
    /// Presentation + content for the popover the heavy capsule anchors. It must attach to the
    /// capsule itself — attached to the row, the arrow points at the row's centre and the popover
    /// reads as disconnected from the control that opened it.
    var heavyPopoverPresented: Binding<Bool>?
    var heavyPopoverContent: (() -> AnyView)?

    @State private var isHoveringCapsule = false

    var body: some View {
        HStack(spacing: 13) {
            // Only the badge and the filename open the file. Making the whole row clickable turns
            // it into one large hit target that also swallows clicks meant for the trailing
            // controls, and gives no hint about what the click will do.
            HStack(spacing: 13) {
                fileBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .themeFont(.bodyEmphasis)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta).themeFont(.micro).foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .modifier(RowOpenModifier(onOpen: onOpen))

            Spacer(minLength: Theme.Spacing.small)
            trailing
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
    }

    private var fileBadge: some View {
        PDFThumbnail(url: fileURL)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .queued(let detail, let savedPercent):
            HStack(spacing: 11) {
                if let detail {
                    Text(detail).themeFont(.micro).foregroundStyle(Theme.Colors.textTertiary)
                }
                if let savedPercent, savedPercent > 0 {
                    StatPill(text: "−\(savedPercent)%", tone: .success)
                }
                if let onRemove {
                    removeButton(onRemove)
                }
            }
        case .analysing:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Analysing…").themeFont(.micro).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .inProgress(let fraction):
            if let fraction {
                ProgressView(value: fraction).frame(width: 110).tint(Theme.Colors.accent)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done(let originalBytes, let newBytes):
            HStack(spacing: 11) {
                Text(byteString(originalBytes))
                    .themeFont(.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .strikethrough()
                Text(byteString(newBytes)).themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                StatPill(text: savedPercentText(originalBytes, newBytes), tone: .success)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.success)
            }
        case .doneHeavy(let originalBytes, let newBytes):
            HStack(spacing: 11) {
                Text(byteString(originalBytes)).themeFont(.micro)
                    .foregroundStyle(Theme.Colors.textTertiary).strikethrough()
                Text(byteString(newBytes)).themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
                // A heavy row can legitimately show no saving (switched to the parked original,
                // R6/R7) — a "−0%" success pill there is nonsense, so it is dropped.
                if newBytes < originalBytes {
                    StatPill(text: savedPercentText(originalBytes, newBytes), tone: .success)
                }
                heavyCapsule
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.success)
            }
            // The capsule makes this the widest trailing cluster; without fixedSize, width
            // pressure wraps the pill onto two lines and grows the row (R8's single-line
            // height). The name column absorbs the squeeze instead (lineLimit + middle
            // truncation).
            .fixedSize()
        case .succeeded(let message):
            Label {
                Text(message).themeFont(.micro).lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(Theme.Colors.success)
        case .unchanged(let message):
            Label {
                Text(message).themeFont(.micro).lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        case .error(let message):
            Label {
                Text(message).themeFont(.micro).lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        }
    }

    /// "Heavy compression ⌄" — neutral tag + affordance that it opens something (spec R8).
    private var heavyCapsule: some View {
        Button { onHeavyTap?() } label: {
            HStack(spacing: 4) {
                Text("Heavy compression").themeFont(.microBold)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(isHoveringCapsule ? Theme.Colors.link : Theme.Colors.textSecondary)
            .fixedSize()
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(Capsule().fill(Theme.Colors.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHoveringCapsule = $0 }
        .popover(isPresented: heavyPopoverPresented ?? .constant(false), arrowEdge: .bottom) {
            if let heavyPopoverContent {
                heavyPopoverContent()
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.Colors.surface))
        }
        .buttonStyle(.plain)
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func savedPercentText(_ original: Int, _ new: Int) -> String {
        guard original > 0 else { return "0%" }
        let pct = Int((1 - Double(new) / Double(original)) * 100)
        return "\u{2212}\(pct)%"
    }
}

/// Every `Status` in one stack — the states the two tools actually reach.
private var fileRowStateGallery: some View {
    VStack(spacing: 8) {
        FileRow(name: "Annual-Report-2025.pdf", meta: "24.1 MB", status: .queued(detail: "≈6.3 MB predicted", savedPercent: 74))
        FileRow(name: "Board-Minutes.pdf", meta: "3.2 MB", status: .analysing)
        FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB", status: .inProgress(fraction: 0.62))
        FileRow(name: "User-Manual.pdf", meta: "19.3 MB", status: .inProgress(fraction: nil))
        FileRow(name: "Product-Brochure.pdf", meta: "5.4 MB", status: .done(originalBytes: 5_400_000, newBytes: 1_400_000))
        FileRow(name: "Receipts.pdf", meta: "2.1 MB", status: .succeeded("Searchable — 12 pages"))
        FileRow(name: "Already-Tiny.pdf", meta: "184 KB", status: .unchanged("Already optimised"))
        FileRow(name: "Encrypted.pdf", meta: "—", status: .error("Password protected"))
    }
    .padding(24)
}

#Preview("FileRow – Light") {
    fileRowStateGallery
        .background(Theme.Colors.surface)
        .preferredColorScheme(.light)
}

#Preview("FileRow – Dark") {
    fileRowStateGallery
        .background(Theme.Colors.surface)
        .preferredColorScheme(.dark)
}

// MARK: - PDFThumbnail

/// A preview of a PDF's first page with a small red PDF label beneath it.
///
/// A generic badge told the user nothing they did not already know from the filename; the page
/// itself is how anyone actually recognises a document. Rendering happens off the main actor —
/// `PDFDocument(url:)` reads and parses the whole file, which for a large scan is far too much
/// work to do while the row is being laid out.
struct PDFThumbnail: View {
    let url: URL?
    var width: CGFloat = 30

    @State private var preview: NSImage?

    private var height: CGFloat { (width * 1.3).rounded() }         // roughly A4/Letter proportions
    /// A fifth of the card. Deep enough to hold the label comfortably, shallow enough that the
    /// thumbnail still reads as a page with a footer rather than a label with a picture above it.
    private var bandHeight: CGFloat { (height * 0.21).rounded() }
    private let radius: CGFloat = 4.5

    var body: some View {
        VStack(spacing: 0) {
            page
            // Flush to the card's edges and centred by its own frame, so the label sits in the
            // base of the document rather than floating under it.
            Text("PDF")
                .font(.system(size: 6, weight: .heavy))
                .kerning(0.35)
                .foregroundStyle(.white)
                .frame(width: width, height: bandHeight)
                .background(Theme.Colors.documentBadge)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
        )
        // Two shadows, not one: a tight contact shadow anchors the card to the row, and a wider,
        // fainter one gives it depth. A single mid-radius shadow reads as a grey smudge at this
        // size and is most of why the first attempt looked cheap.
        .shadow(color: .black.opacity(0.28), radius: 0.8, x: 0, y: 0.5)
        .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 1.5)
        .task(id: url) { await loadPreview() }
    }

    /// The page itself, filling the card above the label band.
    private var page: some View {
        ZStack {
            Color.white
            if let preview {
                // Fill and crop rather than fit: a letterboxed thumbnail leaves grey bars inside
                // what is meant to read as a sheet of paper. The top of the page is the
                // recognisable part, so the crop is anchored there.
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height - bandHeight, alignment: .top)
            }
            // No spinner while loading: a row per file each flickering its own spinner makes a
            // whole batch look broken, and a blank sheet is the honest preview of a blank page.
        }
        .frame(width: width, height: height - bandHeight)
        .clipped()
    }

    private func loadPreview() async {
        preview = nil
        guard let url else { return }
        let pixels = CGSize(width: width * 3, height: height * 3)   // 3x, so it stays crisp on Retina
        let rendered = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: pixels, for: .mediaBox)
        }.value
        guard !Task.isCancelled else { return }
        preview = rendered
    }
}

// MARK: - ToolIconTile

/// A tool's identity glyph: an SF Symbol on a rounded, accent-filled square (the mockup's
/// sidebar and header tile). The mockup gives each tool its own colour; this stays on the one
/// `Theme.Colors.accent` because DESIGN.md §7 spends the entire chromatic budget on that blue —
/// DESIGN.md wins the conflict. Unavailable tools are dimmed by their row, not re-coloured.
struct ToolIconTile: View {
    let systemImage: String
    var size: CGFloat = 22
    var tint: Color = Theme.Colors.accent

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - SectionLabel

/// A small uppercase group label above a cluster of controls ("QUALITY", "ACCURACY"). The
/// positive `tracking` deliberately overrides `microBold`'s negative value: DESIGN.md tracks
/// tight for *reading* text, and uppercase micro-labels need the air back (the mockup sets
/// +0.4px on exactly these labels).
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .themeFont(.microBold)
            .tracking(0.4)
            .foregroundStyle(Theme.Colors.textTertiary)
    }
}

// MARK: - ToolHeader

/// The detail pane's header strip: tool glyph, name and a one-line descriptor above a hairline
/// rule — the mockup's content toolbar. Takes plain strings rather than a `Tool` so the design
/// system stays independent of the app's model layer.
struct ToolHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String
    /// The owning tool's tint. Required in practice: leaving it to `ToolIconTile`'s default drew
    /// the header tile in the accent blue while the sidebar drew the same glyph in the tool's own
    /// colour, so one tool appeared in two colours on screen at once.
    var tint: Color = Theme.Colors.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                ToolIconTile(systemImage: systemImage, tint: tint)
                Text(title).themeFont(.cardTitle).foregroundStyle(Theme.Colors.text)
            }
            Text(subtitle)
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.surface)
        // An explicit hairline rather than `Divider()`: a bare Divider outside a stack takes its
        // orientation from context, and this one lives in an overlay. The mockup's rule is
        // 0.5px at ~9% ink, which reads the same in both appearances off `textTertiary`.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.textTertiary.opacity(0.2))
                .frame(height: 0.5)
        }
    }
}

private var toolChromeGallery: some View {
    VStack(alignment: .leading, spacing: 0) {
        ToolHeader(
            systemImage: "arrow.down.right.and.arrow.up.left",
            title: "Compress",
            subtitle: "Shrink large PDFs. Text and vectors stay sharp; images are re-encoded."
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel("Quality")
            HStack(spacing: Theme.Spacing.small) {
                ToolIconTile(systemImage: "text.viewfinder")
                ToolIconTile(systemImage: "square.stack.3d.up.fill")
                ToolIconTile(systemImage: "text.viewfinder", size: 34)
            }
        }
        .padding(Theme.Spacing.large)
    }
    .frame(width: 520, alignment: .leading)
    .background(Theme.Colors.surface)
}

#Preview("Tool chrome – Light") {
    toolChromeGallery.preferredColorScheme(.light)
}

#Preview("Tool chrome – Dark") {
    toolChromeGallery.preferredColorScheme(.dark)
}

// MARK: - Composite preview (integration check)

#Preview("Compress — Ready (Light)") {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        HStack {
            Text("3 files · 48.2 MB").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
            Spacer()
            Text("+ Add").themeFont(.link).foregroundStyle(Theme.Colors.link)
            Text("Clear").themeFont(.link).foregroundStyle(Theme.Colors.link)
        }
        VStack(spacing: 8) {
            FileRow(name: "Annual-Report-2025.pdf", meta: "24.1 MB", status: .queued(detail: "≈6.3 MB predicted", savedPercent: 74))
            FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB", status: .queued(detail: "≈4.9 MB predicted", savedPercent: 78))
            FileRow(name: "Product-Brochure.pdf", meta: "5.4 MB", status: .queued(detail: "~1.4 MB predicted", savedPercent: 61))
        }
        SegmentedPreset(options: previewPresetOptions, selection: .constant("balanced"))
        HStack {
            Text("Save to").themeFont(.body).foregroundStyle(Theme.Colors.textSecondary)
            Text("Alongside originals").themeFont(.bodyEmphasis).foregroundStyle(Theme.Colors.text)
            Spacer()
            Text("Change…").themeFont(.link).foregroundStyle(Theme.Colors.link)
        }
        .padding(Theme.Spacing.small + 2)
        .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
        HStack {
            Text("Originals are never modified.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            PrimaryButton(title: "Compress 3 PDFs") {}
        }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 560)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.light)
}

extension View {
    /// Show the hand ("this is clickable") cursor while the pointer is inside.
    ///
    /// SwiftUI leaves the arrow in place for a tappable card, so a control built from a card
    /// rather than a `Button` gives the user no hover affordance at all.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

/// Backs `pointingHandCursor()`. Uses `NSCursor.set()` rather than `push()`/`pop()`: a pushed
/// cursor is only balanced by a matching `onHover(false)` on the *same* view instance, but a row
/// can leave mid-hover with no such event (removed from a list, its modifier swapped out when a
/// control becomes disabled, an `onOpen` going non-nil to nil) — leaking the hand cursor for the
/// rest of the session. `set()` has no stack to unbalance, and the `@State` flag plus
/// `onDisappear` make sure a torn-down view still restores the arrow.
private struct PointingHandCursorModifier: ViewModifier {
    @State private var isShowingHandCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                isShowingHandCursor = isInside
                (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .onDisappear {
                if isShowingHandCursor {
                    isShowingHandCursor = false
                    NSCursor.arrow.set()
                }
            }
    }
}

/// The mockup's completion banner: a green tick beside the headline saving and a detail line.
struct SuccessBanner: View {
    let headline: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Colors.success)
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).themeFont(.cardTitle).foregroundStyle(Theme.Colors.text)
                Text(detail).themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.success.opacity(0.12))
        )
    }
}

/// A thin determinate bar. Width animates linearly, matching the mockup's `width .18s linear`.
struct LinearProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.text.opacity(0.12))
                Capsule()
                    .fill(Theme.Colors.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .animation(.linear(duration: 0.18), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

/// Makes a row open its file on click, and shows the hand cursor, only when an action exists.
private struct RowOpenModifier: ViewModifier {
    let onOpen: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpen {
            content
                .onTapGesture(perform: onOpen)
                .pointingHandCursor()
                .help("Open this PDF")
        } else {
            content
        }
    }
}

/// Applies the hand cursor only when a control is enabled.
private struct HandCursorWhen: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.pointingHandCursor() } else { content }
    }
}
