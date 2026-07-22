// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// Reusable components built on `Theme`, rebuilt from the Claude Design mockup
/// (`(kept outside this repository)`) — matching its feel, not its pixels.
/// Presentation-only: none of these depend on `ToolJob`/`CompressPreset`/view-model state, so
/// they stay reusable across Compress, OCR and future tools. Application to the real views
/// (`CompressView`, `OCRView`, `RootView`, `SidebarView`) is the S.1 polish pass, not this task.

// MARK: - PrimaryButton

/// The signature Apple pill CTA (DESIGN.md §7: "980px pill radius... the signature Apple link
/// shape"). Filled with `Theme.Colors.accent`, white label, disabled/hover states.
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
            in: RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
        )
        .shadow(color: Theme.Colors.accent.opacity(isEnabled ? 0.35 : 0), radius: 4, x: 0, y: 2)
        .opacity(isEnabled ? (isHovering ? 0.9 : 1) : 0.4)
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
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

/// One file in a batch queue (DESIGN.md handover §5 "File-queue row"). Covers every state the
/// spec calls for: queued (with remove), in-progress (determinate or indeterminate), done
/// (original→new + saved badge), already-optimised, and error — inline, so a failing file in a
/// batch doesn't disrupt the rest of the list.
struct FileRow: View {
    enum Status {
        case queued
        case inProgress(fraction: Double?)
        case done(originalBytes: Int, newBytes: Int)
        case alreadyOptimised
        case error(String)
    }

    let name: String
    let meta: String
    var status: Status = .queued
    var onRemove: (() -> Void)?

    var body: some View {
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
            Spacer(minLength: Theme.Spacing.small)
            trailing
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
    }

    private var fileBadge: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.Colors.documentBadge)
            .frame(width: 26, height: 32)
            .overlay(
                Text("PDF").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .queued:
            if let onRemove {
                removeButton(onRemove)
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
        case .alreadyOptimised:
            Label {
                Text("Already optimised").themeFont(.micro)
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

#Preview("FileRow – Light") {
    VStack(spacing: 8) {
        FileRow(name: "Annual-Report-2025.pdf", meta: "24.1 MB · 88 pages", status: .queued, onRemove: {})
        FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB", status: .inProgress(fraction: 0.62))
        FileRow(name: "Product-Brochure.pdf", meta: "6 pages", status: .done(originalBytes: 5_400_000, newBytes: 1_400_000))
        FileRow(name: "Already-Tiny.pdf", meta: "1 page", status: .alreadyOptimised)
        FileRow(name: "Encrypted.pdf", meta: "—", status: .error("Password protected"))
    }
    .padding(24)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.light)
}

#Preview("FileRow – Dark") {
    VStack(spacing: 8) {
        FileRow(name: "Annual-Report-2025.pdf", meta: "24.1 MB · 88 pages", status: .queued, onRemove: {})
        FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB", status: .inProgress(fraction: nil))
        FileRow(name: "Product-Brochure.pdf", meta: "6 pages", status: .done(originalBytes: 5_400_000, newBytes: 1_400_000))
        FileRow(name: "Already-Tiny.pdf", meta: "1 page", status: .alreadyOptimised)
        FileRow(name: "Encrypted.pdf", meta: "—", status: .error("Password protected"))
    }
    .padding(24)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
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
            FileRow(name: "Annual-Report-2025.pdf", meta: "24.1 MB · 88 pages", status: .queued, onRemove: {})
            FileRow(name: "Scanned-Contract.pdf", meta: "18.7 MB · 12 pages", status: .queued, onRemove: {})
            FileRow(name: "Product-Brochure.pdf", meta: "5.4 MB · 6 pages", status: .queued, onRemove: {})
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
