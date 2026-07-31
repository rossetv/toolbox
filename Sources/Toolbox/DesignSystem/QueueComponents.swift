// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

// MARK: - VerbChip

/// A batch-wide verb toggle (Compress/OCR) — a compound control: tapping the label toggles the
/// verb on/off, tapping the suffix/chevron (only present once the verb is on and has options)
/// opens that verb's options popover. Two separate VoiceOver actions/labels (spec §9).
///
/// The press scale lands on each half's own content rather than on the whole chip: the pill is a
/// background shared by two `Button`s, so no single `configuration.label` covers it. Squeezing the
/// half actually being pressed is also the more honest read of a two-target control — the handoff
/// defines no active style for chips at all (DESIGN.md §11).
struct VerbChip: View {
    let title: String
    var suffix: String?
    let isOn: Bool
    let icon: Image
    let toggle: () -> Void
    var openOptions: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringToggle = false
    @State private var isHoveringOptions = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    icon.font(.system(size: 13, weight: .semibold))
                    Text(title).themeFont(.bodyStrong)
                }
                .foregroundStyle(isOn ? .white : Theme.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(MotionButtonStyle())
            .clearsClickFocus()
            .accessibilityLabel("\(title), \(isOn ? "on" : "off")")
            .accessibilityHint(isOn ? "Double-tap to turn off" : "Double-tap to turn on")
            .accessibilityAddTraits(isOn ? [.isSelected] : [])

            if isOn, let openOptions {
                Button(action: openOptions) {
                    HStack(spacing: 0) {
                        if let suffix {
                            Text(" · \(suffix)").themeFont(.body13).opacity(0.75)
                                .foregroundStyle(.white)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(isHoveringOptions ? 1 : 0.85))
                            .padding(.leading, 6)
                            .padding(.trailing, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MotionButtonStyle())
                .clearsClickFocus()
                .continuousHover($isHoveringOptions)
                .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringOptions)
                .accessibilityLabel("\(title) options")
                .accessibilityHint("Opens \(title.lowercased()) settings")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(
            isOn ? Theme.Colors.accent : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.Colors.stroke, lineWidth: isOn ? 0 : 1)
        )
        .background(
            (isOn ? Color.white.opacity(isHoveringToggle ? 0.12 : 0) : Theme.Colors.fill.opacity(isHoveringToggle ? 1 : 0)),
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
        .continuousHover($isHoveringToggle)
        .pointingHandCursor()
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringToggle)
        // Turning a verb on/off swaps the pill between accent-filled and outlined, and adds or
        // removes the suffix — a layout change, so it settles on the standard spring rather than
        // snapping.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: isOn)
    }
}

#Preview("VerbChip – states") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            VerbChip(title: "Compress", suffix: "Balanced", isOn: true, icon: Image(systemName: "arrow.down.right.and.arrow.up.left"), toggle: {}, openOptions: {})
            VerbChip(title: "OCR", suffix: nil, isOn: false, icon: Image(systemName: "doc.text.magnifyingglass"), toggle: {})
        }
        HStack(spacing: 8) {
            VerbChip(title: "Compress", suffix: nil, isOn: false, icon: Image(systemName: "arrow.down.right.and.arrow.up.left"), toggle: {})
            VerbChip(title: "OCR", suffix: "English", isOn: true, icon: Image(systemName: "doc.text.magnifyingglass"), toggle: {}, openOptions: {})
        }
    }
    .padding(40)
    .background(Theme.Colors.surface)
}

// MARK: - StatusIndicator

/// The queue row's single trailing status glyph (spec §9: finished/working/waiting + detail, one
/// VoiceOver label). `size` defaults to the row's 16–18px use but is overridable so a screen's
/// big finished/warn header can reuse the same glyph (screens 06/10) rather than a second
/// component — mirrors `ToolIconTile`'s own `size` pattern.
struct StatusIndicator: View {
    enum Kind: Equatable {
        case finished
        case active(Double)
        case queued
        /// A fully successful no-op row ("Already optimised") — an outline check, textTertiary.
        case unchanged
        /// A row-level degraded outcome (spec §6.5: rescued, tooFaint) — structurally the SAME
        /// outline check as `.unchanged`, just tinted `Theme.Colors.warn`. This is deliberately
        /// NOT the filled warn-disc + exclamation that `BatchCard`/a batch-summary header draws
        /// for "this batch needs attention" (screen 10's own header, screen 11's warn sheet row)
        /// — that is a different glyph shape entirely and is drawn by its own view, not this
        /// case; embedding `StatusIndicator(.warn)` there would show the wrong icon.
        case warn
    }

    let kind: Kind
    var size: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var isBreathing = false

    var body: some View {
        Group {
            switch kind {
            case .finished: filledCheck(Theme.Colors.success)
            case .active(let fraction): ring(fraction: fraction)
            case .queued: dashedRing
            case .unchanged: outlineCheck(Theme.Colors.textTertiary)
            case .warn: outlineCheck(Theme.Colors.warn)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .finished: return "Finished"
        case .active(let fraction): return "Working, \(Int((fraction * 100).rounded())) percent"
        case .queued: return "Waiting"
        case .unchanged: return "Unchanged"
        case .warn: return "Needs attention"
        }
    }

    private func filledCheck(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.4)
        .onAppear {
            guard !reduceMotion else { hasAppeared = true; return }
            // DESIGN.md §8: "row checks delay 0.25s after the header check" — every production
            // caller of `.finished` is a per-row check (`QueueRowsView`), never the screen 06/10
            // header disc (`QueueHeaderView.headlineGlyph` pops on its own, undelayed).
            withAnimation(.spring(response: Theme.Motion.checkPop, dampingFraction: 0.58).delay(0.25)) {
                hasAppeared = true
            }
        }
    }

    private func ring(fraction: Double) -> some View {
        ZStack {
            Circle().stroke(Theme.Colors.track, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // Stays animated under Reduce Motion, same as `CapsuleProgressBar`'s fill-width: this
        // ring communicates real per-row progress, not decoration (DESIGN.md §8).
        .animation(.linear(duration: 0.2), value: fraction)
    }

    private var dashedRing: some View {
        Circle()
            .stroke(Theme.Colors.textTertiary, style: StrokeStyle(lineWidth: 1.6, dash: [3, 3.4]))
            .opacity(isBreathing ? 0.5 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                // Autoreverse doubles the duration, so use half for a 2.2s full cycle
                // (handoff: `animation:breathe 2.2s ease-in-out infinite`).
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { isBreathing = true }
            }
    }

    private func outlineCheck(_ color: Color) -> some View {
        ZStack {
            Circle().stroke(color, lineWidth: 1.4)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

#Preview("StatusIndicator – every state") {
    HStack(spacing: 20) {
        VStack { StatusIndicator(kind: .finished); Text("finished").themeFont(.caption) }
        VStack { StatusIndicator(kind: .active(0.62)); Text("active").themeFont(.caption) }
        VStack { StatusIndicator(kind: .queued); Text("queued").themeFont(.caption) }
        VStack { StatusIndicator(kind: .unchanged); Text("unchanged").themeFont(.caption) }
        VStack { StatusIndicator(kind: .warn); Text("warn").themeFont(.caption) }
        VStack { StatusIndicator(kind: .finished, size: 30); Text("finished @30").themeFont(.caption) }
    }
    .padding(40)
    .background(Theme.Colors.surface)
}

// MARK: - CapsuleProgressBar

/// The batch-wide progress bar on the Working screen — gradient accent fill, a glowing leading
/// cap and a light sweep, both gated on Reduce Motion (the fill-width animation, driven by
/// `fraction`, stays — it communicates real progress rather than decoration).
struct CapsuleProgressBar: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = max(0, min(1, fraction)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.track)
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.Colors.accent.opacity(0.74), Theme.Colors.accent],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: width)
                if !reduceMotion {
                    // A separate view, not inline state on the parent: the glow/sweep only exist
                    // in the tree while motion is on, so this child's own `onAppear` fires exactly
                    // when Reduce Motion toggles off (mirrors `QueueRowShimmer`) — inline `@State`
                    // here would survive a Reduce Motion round-trip already at its end value, so
                    // the re-inserted `onAppear` would set the SAME value and animate nothing.
                    CapsuleGlowAndSweep(width: width, totalWidth: geo.size.width)
                }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// The leading-cap glow pulse and the light sweep crossing the filled portion — see
/// `CapsuleProgressBar`'s own comment for why these own their `@State` rather than the parent.
private struct CapsuleGlowAndSweep: View {
    let width: CGFloat
    let totalWidth: CGFloat

    @State private var sweepX: CGFloat = -0.3
    @State private var capGlowOpacity: Double = 0.35

    private static let capWidth: CGFloat = 30

    var body: some View {
        let clampedCapWidth = min(width, Self.capWidth)
        Group {
            Capsule()
                .fill(LinearGradient(
                    colors: [.clear, Color.white.opacity(0.85)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .opacity(capGlowOpacity)
                .frame(width: clampedCapWidth)
                .offset(x: width - clampedCapWidth)
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: totalWidth * 0.26)
                .offset(x: sweepX * totalWidth)
                .frame(width: width, alignment: .leading)
                .clipShape(Capsule())
        }
        .onAppear {
            // Autoreverse doubles the duration, so use half for a 1.6s full cycle.
            withAnimation(.easeInOut(duration: Theme.Motion.capGlow / 2).repeatForever(autoreverses: true)) {
                capGlowOpacity = 0.95
            }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { sweepX = 1.3 }
        }
    }
}

#Preview("CapsuleProgressBar") {
    VStack(spacing: 16) {
        CapsuleProgressBar(fraction: 0.15)
        CapsuleProgressBar(fraction: 0.52)
        CapsuleProgressBar(fraction: 0.95)
    }
    .padding(40)
    .frame(width: 400)
    .background(Theme.Colors.surface)
}

// MARK: - OptionCard

/// One of screen 08's equal-width quality cards: name, predicted total, delta caption, selection
/// ring. NOT screen 04's quality popover (that's `RadioRow` — see the file-top map).
struct OptionCard: View {
    enum Tone {
        case success, muted, plain
        var color: Color {
            switch self {
            case .success: return Theme.Colors.success
            case .muted: return Theme.Colors.textTertiary
            case .plain: return Theme.Colors.textTertiary
            }
        }
    }

    let title: String
    let value: String
    let caption: String
    var captionTone: Tone = .plain
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textSecondary)
                    Text(caption)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(captionTone.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            // Fill and selection ring live inside the label so `MotionButtonStyle`'s press scale
            // carries the whole card; `contentShape` stays after the padding.
            .background(
                isSelected ? Theme.Colors.accent.opacity(0.08) : (isHovering ? Theme.Colors.background : Theme.Colors.surface),
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Colors.accent : Theme.Colors.stroke, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .continuousHover($isHovering)
        .pointingHandCursor()
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        // Moving the selection ring and tint from one card to the next is the sheet's main event
        // — it settles on the standard spring rather than cutting.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel("\(title), \(value), \(caption)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("OptionCard – every state") {
    HStack(spacing: 8) {
        OptionCard(title: "Smallest", value: "6.2 MB", caption: "4.2 MB less", captionTone: .success, isSelected: false, action: {})
        OptionCard(title: "Balanced", value: "10.4 MB", caption: "what you have", captionTone: .muted, isSelected: false, action: {})
        OptionCard(title: "High quality", value: "23.0 MB", caption: "for printing", captionTone: .plain, isSelected: true, action: {})
    }
    .padding(40)
    .frame(width: 560)
    .background(Theme.Colors.surface)
}

// MARK: - CapsuleBadge

/// The "N versions" capsule embedded in a finished `QueueRow` (screens 06/07/12) — the only
/// render that actually draws a pill-shaped badge with two tones (closed = muted fill/text2,
/// open = solid accent/white). Screen 04's RECOMMENDED tag and screen 09's BEST FOR
/// SCANS/NOTHING REDRAWN labels are NOT this component — the html draws them as plain coloured
/// text with no capsule background at all (see the file-top map); forcing them through
/// `CapsuleBadge` would draw an unwanted pill.
struct CapsuleBadge: View {
    enum Tone { case accent, muted }

    let text: String
    var tone: Tone = .accent
    /// The small stack glyph accompanying "N versions" — optional so a future plain-text badge
    /// use isn't forced to carry one.
    var icon: Image? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            icon?.font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tone == .accent ? .white : Theme.Colors.textSecondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .background(background, in: Capsule())
        .continuousHover($isHovering)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: tone)
    }

    /// The handoff deepens the closed capsule's fill to `track` on hover
    /// (`style-hover="background:var(--track)"`); the open (accent) capsule already reads as
    /// pressed-in and does not change.
    private var background: Color {
        switch tone {
        case .accent: return Theme.Colors.accent
        case .muted: return isHovering ? Theme.Colors.track : Theme.Colors.fill
        }
    }
}

#Preview("CapsuleBadge") {
    HStack(spacing: 10) {
        CapsuleBadge(text: "3 versions", tone: .muted, icon: Image(systemName: "square.3.layers.3d"))
        CapsuleBadge(text: "3 versions", tone: .accent, icon: Image(systemName: "square.3.layers.3d"))
    }
    .padding(40)
    .background(Theme.Colors.surface)
}

// MARK: - QueueRowSizeColumn

/// The 70pt right-aligned trailing size column (README §Screens 03: "predicted size … in a 70px
/// right-aligned column") used by every "current → target size" `QueueRow.trailing`
/// composition — screen 03's ready rows, screen 08's per-file mechanism lines. One definition so
/// every screen sharing this shape uses the same column width rather than three tracks each
/// re-deriving the 70pt magic number independently.
struct QueueRowSizeColumn: View {
    let current: String
    let target: String
    /// Screen 08's nothing-to-change row (html: `only-08.html` 649-655): the arrow collapses to
    /// a same-width spacer (keeping the 70pt column aligned with changed rows) and `target`
    /// drops to the SAME grey/small styling as `current`.
    var sameSize: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Text(current).themeFont(.body13).foregroundStyle(Theme.Colors.textTertiary)
            if sameSize {
                Color.clear.frame(width: 9, height: 1)
            } else {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(target)
                .themeFont(sameSize ? .body13 : .rowName)
                .foregroundStyle(sameSize ? Theme.Colors.textTertiary : Theme.Colors.textSecondary)
                .frame(width: 70, alignment: .trailing)
        }
    }
}

#Preview("QueueRowSizeColumn") {
    VStack(alignment: .trailing, spacing: 8) {
        QueueRowSizeColumn(current: "24.1 MB", target: "6.3 MB")
        QueueRowSizeColumn(current: "4.1 MB", target: "8.9 MB")
    }
    .padding(24)
    .background(Theme.Colors.surface)
}

// MARK: - QueueRow

/// The queue's one row shape, covering every screen it appears on (03 ready, 05 working, 06/12
/// finished, 07 mid-choice, 10 problems). Trailing content is generic — each screen composes
/// whatever it needs (a size pair, a `StatusIndicator`, problem affordances) from the rest of
/// this file — because the shapes genuinely differ screen to screen; what stays fixed here is
/// the shared mechanics: hover/keyboard-focus, the leading thumbnail+name+meta, the hover- and
/// focus-revealed gear, the versions capsule, problem-row tinting, and the context menu that
/// mirrors every hover-only affordance for the non-hover/keyboard path (spec §9).
struct QueueRow<Trailing: View>: View {
    enum Emphasis {
        case none
        /// Rescued/tooFaint (spec §6.5) — no background tint; pair with `StatusIndicator.warn`
        /// in `trailing`.
        case degraded
        /// Screen 05's currently-processing row (DESIGN.md §9 05, spec §7): accent-tinted
        /// background, a slow (~2.4s) shimmer sweep gated on Reduce Motion, and accent-coloured
        /// `meta` text.
        case active
        /// Screen 10's danger-tinted problem row (locked file).
        case problemDanger
        /// Screen 10's warn-tinted problem row (moved/renamed file).
        case problemWarn
    }

    let name: String
    let meta: String
    /// `.accent` by default (the "Its own settings" register); a caller reporting a failed
    /// action (R12) passes `.danger` instead. Nil when the row has no accent text at all.
    var metaAccent: (text: String, colour: Color)? = nil
    var fileURL: URL? = nil
    var emphasis: Emphasis = .none

    var onOpen: (() -> Void)? = nil
    var onGear: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var versionsCapsuleTitle: String? = nil
    var isVersionsCapsuleOpen: Bool = false
    var onVersionsCapsule: (() -> Void)? = nil

    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isHoveringGear = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer(minLength: Theme.Spacing.small)
            if onGear != nil, isHovering || isFocused {
                gearButton
                    // The handoff fades the gear in ahead of the sizes rather than popping it
                    // into the row; it leaves the same way.
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            if let versionsCapsuleTitle {
                Button(action: { onVersionsCapsule?() }) {
                    CapsuleBadge(
                        text: versionsCapsuleTitle,
                        tone: isVersionsCapsuleOpen ? .accent : .muted,
                        icon: Image(systemName: "square.3.layers.3d")
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(MotionButtonStyle())
                .clearsClickFocus()
                .pointingHandCursor()
                .accessibilityLabel("Choose a version, \(versionsCapsuleTitle)")
            }
            trailing()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay {
            if isActive, !reduceMotion {
                QueueRowShimmer()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Theme.Colors.accent, lineWidth: isFocused ? 2 : 0)
        )
        .contentShape(Rectangle())
        .focusable(onOpen != nil)
        .focused($isFocused)
        .continuousHover($isHovering)
        // The hover fill fades in (handoff `transition:background .15s`); the gear it also
        // reveals rides the same change, so both are keyed off one animation.
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isFocused)
        // A row changing state mid-run (queued → active → finished) re-tints its background and
        // re-lays its trailing column; the standard spring keeps that from flickering.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: emphasis)
        .modifier(RowOpenModifier(onOpen: onOpen))
        .onKeyPress(.return) {
            guard let onOpen else { return .ignored }
            onOpen()
            return .handled
        }
        .contextMenu {
            if let onGear {
                Button("Settings…", action: onGear)
            }
            if let onVersionsCapsule {
                Button("Versions…", action: onVersionsCapsule)
            }
            if let onRemove {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var leading: some View {
        HStack(spacing: 13) {
            PDFThumbnail(url: fileURL).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).themeFont(.rowName).foregroundStyle(Theme.Colors.text)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(meta).themeFont(.meta).foregroundStyle(metaTextColor)
                    if let metaAccent {
                        Text(metaAccent.text).themeFont(.meta).foregroundStyle(metaAccent.colour).lineLimit(1)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gearButton: some View {
        Button(action: { onGear?() }) {
            Image(systemName: "gearshape")
                // Handoff: `transition:background .15s,color .15s`, hovering to
                // `background:var(--bg);color:var(--text)`.
                .foregroundStyle(isHoveringGear ? Theme.Colors.text : Theme.Colors.textSecondary)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(isHoveringGear ? Theme.Colors.background : Theme.Colors.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .pointingHandCursor()
        .continuousHover($isHoveringGear)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringGear)
        .accessibilityLabel("Settings for \(name)")
    }

    private var isActive: Bool {
        if case .active = emphasis { return true }
        return false
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .none, .degraded:
            return isHovering ? Theme.Colors.background : .clear
        case .active:
            // `Toolbox Final.dc.html` screen 05's active row: `color-mix(in srgb, var(--accent)
            // 7%, transparent)`.
            return Theme.Colors.accent.opacity(0.07)
        case .problemDanger:
            return Theme.Colors.danger.opacity(0.07)
        case .problemWarn:
            return Theme.Colors.warn.opacity(0.1)
        }
    }

    private var metaTextColor: Color {
        isActive ? Theme.Colors.accent : Theme.Colors.textTertiary
    }

    private var accessibilityLabel: String {
        var label = "\(name), \(meta)"
        if let metaAccent { label += ", \(metaAccent.text)" }
        switch emphasis {
        case .problemDanger, .problemWarn: label += ", needs attention"
        case .degraded: label += ", needs attention"
        case .none, .active: break
        }
        return label
    }
}

/// The active row's ~2.4s sweep (DESIGN.md §8), a soft light band travelling across the row —
/// same shape as `CapsuleProgressBar`'s sweep, clipped to the row so it never bleeds past the
/// rounded corners. This only exists in the view tree while the row is active (`QueueRow`'s
/// overlay is conditional on `isActive`), so its own `onAppear` fires exactly when the sweep
/// should (re)start — fixing the row that goes active only after its first appearance, whose
/// shimmer would otherwise never start. Reduce Motion is gated by the caller, which only
/// instantiates this view when motion is allowed.
private struct QueueRowShimmer: View {
    @State private var shimmerX: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, Color.white.opacity(0.5), .clear],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: geo.size.width * 0.32)
                .offset(x: shimmerX * geo.size.width)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shimmerX = 1.3 }
        }
    }
}

#Preview("QueueRow – ready (size column)") {
    VStack(spacing: 2) {
        QueueRow(name: "Annual-Report-2025.pdf", meta: "48 pages, mostly photographs", onOpen: {}, onGear: {}) {
            QueueRowSizeColumn(current: "24.1 MB", target: "6.3 MB")
        }
    }
    .padding(24)
    .frame(width: 620)
    .background(Theme.Colors.surface)
}

#Preview("QueueRow – working (finished/active/queued)") {
    VStack(spacing: 2) {
        QueueRow(name: "Annual-Report-2025.pdf", meta: "75% smaller · finished in 12 seconds") {
            HStack(spacing: 9) {
                Text("6.1 MB").themeFont(.rowName).foregroundStyle(Theme.Colors.text)
                StatusIndicator(kind: .finished)
            }
        }
        QueueRow(name: "Scanned-Contract.pdf", meta: "Reading page 19 of 32") {
            HStack(spacing: 9) {
                Text("8s left").themeFont(.body13).foregroundStyle(Theme.Colors.textTertiary)
                StatusIndicator(kind: .active(0.6))
            }
        }
        QueueRow(name: "Product-Brochure.pdf", meta: "Next") {
            HStack(spacing: 9) {
                Text("1.4 MB").themeFont(.rowName).foregroundStyle(Theme.Colors.textTertiary)
                StatusIndicator(kind: .queued)
            }
        }
    }
    .padding(24)
    .frame(width: 620)
    .background(Theme.Colors.surface)
}

#Preview("QueueRow – finished w/ versions + unchanged") {
    VStack(spacing: 2) {
        QueueRow(
            name: "Scanned-Contract.pdf", meta: "Rebuilt and searchable · 78% smaller",
            onOpen: {}, versionsCapsuleTitle: "3 versions", onVersionsCapsule: {}
        ) {
            HStack(spacing: 9) {
                Text("4.1 MB").themeFont(.rowName).foregroundStyle(Theme.Colors.text)
                StatusIndicator(kind: .finished)
            }
        }
        QueueRow(name: "Meeting-Notes.pdf", meta: "Already optimised", onOpen: {}) {
            HStack(spacing: 9) {
                Text("184 KB").themeFont(.rowName).foregroundStyle(Theme.Colors.textTertiary)
                StatusIndicator(kind: .unchanged)
            }
        }
    }
    .padding(24)
    .frame(width: 620)
    .background(Theme.Colors.surface)
}

#Preview("QueueRow – problems + degraded") {
    VStack(spacing: 2) {
        QueueRow(name: "Bank-Statement.pdf", meta: "Needs a password to open", emphasis: .problemDanger) {
            HStack(spacing: 10) {
                SecondaryButton(title: "Enter password…", action: {})
                LinkButton(title: "Skip", action: {})
            }
        }
        QueueRow(name: "Site-Survey.pdf", meta: "Moved or renamed since you added it", emphasis: .problemWarn) {
            HStack(spacing: 10) {
                SecondaryButton(title: "Find it…", action: {})
                LinkButton(title: "Remove", action: {})
            }
        }
        QueueRow(name: "Faxed-Order.pdf", meta: "Too faint to read — compressed, but not searchable", emphasis: .degraded, onOpen: {}) {
            HStack(spacing: 9) {
                Text("0.8 MB").themeFont(.rowName).foregroundStyle(Theme.Colors.text)
                StatusIndicator(kind: .warn)
            }
        }
    }
    .padding(24)
    .frame(width: 640)
    .background(Theme.Colors.surface)
}

// MARK: - BatchCard

/// A recent-batch summary tile — the empty-state history strip (screen 01, `trailingLink`
/// "Open folder") and the Recent-batches sheet's rows (screen 11, `trailingValue`, a plain
/// savings figure since the WHOLE row opens the folder there — see the file-top map). The two
/// trailing fields are mutually exclusive; a caller supplies at most one.
struct BatchCard: View {
    let icon: StatusIndicator.Kind
    let title: String
    let subtitle: String
    var trailingLink: (title: String, action: () -> Void)? = nil
    var trailingValue: (text: String, isMuted: Bool)? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle).themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer(minLength: Theme.Spacing.small)
                if let trailingLink {
                    LinkButton(title: trailingLink.title, action: trailingLink.action)
                }
                if let trailingValue {
                    Text(trailingValue.text)
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(trailingValue.isMuted ? Theme.Colors.textTertiary : Theme.Colors.success)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            // Inside the label so the press scale carries the whole tile (see
            // `MotionButtonStyle`); `contentShape` stays after the padding.
            .background(isHovering ? Theme.Colors.background : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .continuousHover($isHovering)
        .pointingHandCursor()
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    /// The 26px tinted rounded-square badge — a filled disc + glyph, distinct from
    /// `StatusIndicator`'s row-level outline glyphs (see `StatusIndicator.warn`'s doc comment).
    private var badge: some View {
        let (tint, symbol): (Color, String) = {
            switch icon {
            case .finished: return (Theme.Colors.success, "checkmark")
            case .warn: return (Theme.Colors.warn, "exclamationmark")
            default: return (Theme.Colors.textTertiary, "checkmark")
            }
        }()
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 26, height: 26)
            .overlay(
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 16, height: 16)
            )
    }
}

#Preview("BatchCard – empty-state strip + sheet row") {
    VStack(spacing: 8) {
        BatchCard(icon: .finished, title: "3 files in Contracts", subtitle: "14:22 · 21.2 MB smaller",
                  trailingLink: (title: "Open folder", action: {}), action: {})
        BatchCard(icon: .warn, title: "4 of 5 files in Invoices", subtitle: "11:05 · one was password-locked",
                  trailingLink: (title: "Open folder", action: {}), action: {})
        Divider()
        BatchCard(icon: .finished, title: "3 files in Contracts", subtitle: "14:22 · Balanced · one made searchable",
                  trailingValue: (text: "21.2 MB", isMuted: false), action: {})
        BatchCard(icon: .finished, title: "12 scans in Desktop › Scans", subtitle: "18:40 · OCR only · all searchable",
                  trailingValue: (text: "no change", isMuted: true), action: {})
    }
    .padding(24)
    .frame(width: 480)
    .background(Theme.Colors.surface)
}

// MARK: - VariantCard

/// One of screen 09's two scan-choice cards. The "BEST FOR SCANS"/"NOTHING REDRAWN" label is
/// plain coloured `Text` (see the file-top map for why this is not `CapsuleBadge`).
///
/// Deliberately NOT a button: unlike every other interactive element in
/// `Toolbox Final.dc.html`, neither card carries `cursor:pointer` nor a hover style — selection
/// happens exclusively through the footer's two equal-weight buttons ("Keep photographs"/"Keep
/// rebuilt"), composed by the caller from `SecondaryButton`/`PrimaryButton`. `isSelected` only
/// drives the accent ring/tint that previews which choice is currently leading.
struct VariantCard: View {
    let title: String
    let badgeText: String
    var badgeIsAccent: Bool = true
    let sizeText: String
    let percentText: String
    let explanation: String
    let previewURL: URL?
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.Colors.text)
                Text(badgeText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(badgeIsAccent ? Theme.Colors.accent : Theme.Colors.textTertiary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(sizeText).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textSecondary)
                Text(percentText).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.Colors.success)
            }
            HStack {
                Spacer(minLength: 0)
                PDFThumbnail(url: previewURL, width: 76, plain: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.top, 8)

            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            isSelected ? Theme.Colors.accent.opacity(0.07) : Theme.Colors.background,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Theme.Colors.accent : .clear, lineWidth: 1.5)
        )
        // The card takes no hover or press — the handoff gives it neither (see the doc comment).
        // What it does do is show which choice is currently leading, and the ring/tint moving
        // between the two cards is the only feedback the consent sheet's buttons give.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(sizeText), \(percentText). \(explanation)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("VariantCard – both choices") {
    HStack(alignment: .top, spacing: 14) {
        VariantCard(
            title: "Rebuilt in layers", badgeText: "BEST FOR SCANS", badgeIsAccent: true,
            sizeText: "4.1 MB", percentText: "78% smaller",
            explanation: "Letters are traced and stay crisp at any zoom. The paper behind them is flattened, so grain, shadows and coffee rings disappear.",
            previewURL: nil, isSelected: true
        )
        VariantCard(
            title: "Left as photographs", badgeText: "NOTHING REDRAWN", badgeIsAccent: false,
            sizeText: "6.8 MB", percentText: "64% smaller",
            explanation: "Each page stays a picture of the paper, just lighter. Choose this when the sheet itself is evidence — signatures, stamps, handwriting.",
            previewURL: nil, isSelected: false
        )
    }
    .padding(24)
    .frame(width: 640)
    .background(Theme.Colors.surface)
}

// MARK: - SegmentedRow

/// A compact 2- or 3-way segmented control (screen 04b's Fast/Accurate, screen 04c's quality).
/// Custom-drawn rather than native `.segmented`, matching the design system's own buttons/chips
/// rather than AppKit's chrome.
struct SegmentedRow: View {
    let options: [String]
    @Binding var selection: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Backs the selection pill's slide: one pill drawn in whichever segment is selected, moved
    /// between them by `matchedGeometryEffect` rather than cross-fading two rectangles. This is
    /// the shape the effect exists for — a single element genuinely travelling between slots.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let isSelected = index == selection
                Button {
                    withAnimation(Theme.Motion.standardCurve(reduceMotion: reduceMotion)) { selection = index }
                } label: {
                    Text(options[index])
                        .themeFont(.bodyStrong)
                        .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                                    .fill(Theme.Colors.surface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: pill)
                            }
                        }
                        // Without this an unselected segment is a bare `Text` in a plain-rendering
                        // button: only the glyphs themselves take the click, so the gaps between
                        // letters and the padding around them are dead. Same class as the row/
                        // check-row hit-test fixes; found while adding the press state here.
                        .contentShape(Rectangle())
                }
                .buttonStyle(MotionButtonStyle())
                .clearsClickFocus()
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.Colors.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .pointingHandCursor()
    }
}

#Preview("SegmentedRow – 2-way and 3-way") {
    VStack(spacing: 16) {
        SegmentedRow(options: ["Fast", "Accurate"], selection: .constant(1))
        SegmentedRow(options: ["Smallest", "Balanced", "High"], selection: .constant(2))
    }
    .padding(40)
    .frame(width: 320)
    .background(Theme.Colors.surface)
}

// MARK: - DropdownRow

/// A labelled system dropdown (screen 04b's language picker) — reuses the existing
/// `SectionLabel` for the group label rather than duplicating its uppercase+tracking logic.
struct DropdownRow: View {
    let label: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            } label: { EmptyView() }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(Theme.Typography.body13.font)
        }
    }
}

#Preview("DropdownRow") {
    DropdownRow(label: "Language on the page", options: ["English", "German", "Spanish", "French"], selection: .constant("English"))
        .padding(40)
        .frame(width: 320)
        .background(Theme.Colors.surface)
}

// MARK: - ToggleRow

/// A titled system toggle with a state-line beneath it (screen 04c's "Rebuild the scan"/"Read
/// the text (OCR)").
struct ToggleRow: View {
    let title: String
    let stateLine: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text(stateLine).themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.small)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.Colors.accent)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

#Preview("ToggleRow – on and off") {
    VStack(spacing: 16) {
        ToggleRow(title: "Rebuild the scan", stateLine: "Off — stamps stay photographic", isOn: .constant(false))
        ToggleRow(title: "Read the text (OCR)", stateLine: "English · Accurate", isOn: .constant(true))
    }
    .padding(40)
    .frame(width: 320)
    .background(Theme.Colors.surface)
}

// MARK: - RadioRow

/// A single-select row used by two different popovers (screen 04's quality list, screen 07's
/// versions list) with genuinely different unselected-state chrome, confirmed against
/// `Toolbox Final.dc.html`: screen 04 draws NO glyph at all on an unselected row; screen 07
/// draws a hollow radio ring. `showsUnselectedIndicator` (default `true`, matching screen 07 —
/// the more common "choosing among existing things" case) is the flag; screen 04's popover
/// passes `false`.
struct RadioRow: View {
    enum Tone { case plain, accent }

    let title: String
    let subtitle: String
    let isSelected: Bool
    var subtitleTone: Tone = .plain
    var trailingValue: String? = nil
    var badge: String? = nil
    var showsUnselectedIndicator: Bool = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Whether this row reserves a leading indicator slot at all — screen 04's unselected rows
    /// have no glyph AND no reserved space (title sits flush with the row's padding); only
    /// screen 07's hollow-ring rows (and any selected row) get the 14pt slot + gap.
    private var reservesIndicatorSlot: Bool { isSelected || showsUnselectedIndicator }

    var body: some View {
        Button(action: action) {
            HStack(spacing: reservesIndicatorSlot ? 10 : 0) {
                if reservesIndicatorSlot { indicator }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).foregroundStyle(Theme.Colors.text)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.vertical, 1.5)
                                .padding(.horizontal, 6)
                                .background(Theme.Colors.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(subtitleTone == .accent ? Theme.Colors.accent : Theme.Colors.textTertiary)
                }
                Spacer(minLength: Theme.Spacing.small)
                if let trailingValue {
                    Text(trailingValue)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textSecondary)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            // Inside the label so the press scale carries the row (see `MotionButtonStyle`);
            // `contentShape` stays after the padding.
            .background(
                isSelected ? Theme.Colors.accent.opacity(0.09) : (isHovering ? Theme.Colors.background : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .continuousHover($isHovering)
        .pointingHandCursor()
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
        // Selection moves the accent tint, the title's weight and the dot from one row to the
        // next — one spring so the whole list settles together.
        .animation(Theme.Motion.standardCurve(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Both states are drawn at once and cross-scaled, rather than swapped: the accent dot springs
    /// out of the hollow ring instead of replacing it in one frame. Reduce Motion still gets both
    /// end states — the animation above is simply `nil`, so the swap is instant.
    private var indicator: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.stroke, lineWidth: 1.4)
                .opacity(isSelected ? 0 : 1)
            ZStack {
                Circle().fill(Theme.Colors.accent)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .scaleEffect(isSelected ? 1 : 0.1)
            .opacity(isSelected ? 1 : 0)
        }
        .frame(width: 14, height: 14)
    }
}

#Preview("RadioRow – quality popover (no unselected glyph)") {
    VStack(spacing: 1) {
        RadioRow(title: "Smallest", subtitle: "For email limits. Photographs soften.", isSelected: false,
                 trailingValue: "8.4 MB", showsUnselectedIndicator: false, action: {})
        RadioRow(title: "Balanced", subtitle: "Indistinguishable on screen.", isSelected: true,
                 trailingValue: "12.6 MB", badge: "RECOMMENDED", showsUnselectedIndicator: false, action: {})
        RadioRow(title: "High quality", subtitle: "Safe to print at full size.", isSelected: false,
                 trailingValue: "24.9 MB", showsUnselectedIndicator: false, action: {})
    }
    .padding(10)
    .frame(width: 330)
    .background(Theme.Colors.surface)
}

#Preview("RadioRow – versions popover (hollow ring)") {
    VStack(spacing: 1) {
        RadioRow(title: "Rebuilt · 4.1 MB", subtitle: "In use. Text sharp, paper texture smoothed.",
                  isSelected: true, subtitleTone: .accent, action: {})
        RadioRow(title: "Photographs · 6.8 MB", subtitle: "Pages untouched, only lighter.", isSelected: false, action: {})
        RadioRow(title: "Original · 18.7 MB", subtitle: "Never modified, still in its folder.", isSelected: false, action: {})
    }
    .padding(10)
    .frame(width: 312)
    .background(Theme.Colors.surface)
}

// MARK: - CheckRow

/// A plain checkbox row (screen 08's "Choose which files…" file-selection list).
///
/// The handoff never draws this box — screen 08 only shows the "Choose which files…" link that
/// opens the list — so its motion is beyond-handoff polish under the 2026-08-01 mandate
/// (DESIGN.md §11): the tick is replaced through SF Symbols' own transition rather than cutting
/// between two glyphs, and the box springs up to full size as it fills.
struct CheckRow: View {
    let title: String
    @Binding var isChecked: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Theme.Motion.standardCurve(reduceMotion: reduceMotion)) { isChecked.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isChecked ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    // A tick that lands slightly over-size and settles reads as a press being
                    // answered; the empty box sits a hair under, so ticking grows into place.
                    .scaleEffect(isChecked ? 1 : 0.92)
                Text(title).themeFont(.body13).foregroundStyle(Theme.Colors.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .pointingHandCursor()
        .accessibilityLabel(title)
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }
}

#Preview("CheckRow") {
    VStack(alignment: .leading, spacing: 10) {
        CheckRow(title: "Annual-Report-2025.pdf", isChecked: .constant(true))
        CheckRow(title: "Scanned-Contract.pdf", isChecked: .constant(false))
    }
    .padding(40)
    .frame(width: 320)
    .background(Theme.Colors.surface)
}

// MARK: - Chrome: PopoverChrome / SheetChrome / UpdateBannerChrome

/// Shared popover container — background, corner radius, shadow, anchor tail, and the fade +
/// scale + rise entrance (Reduce Motion: appears instantly, no transform).
struct PopoverChrome<Content: View>: View {
    var width: CGFloat
    /// Horizontal offset of the tail from the popover's leading edge, matching the anchor.
    var tailOffset: CGFloat = 24
    var tailEdge: Edge = .top
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        content()
            .padding(7)
            .frame(width: width)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Colors.stroke, lineWidth: 0.5)
            )
            .overlay(alignment: tailEdge == .top ? .topLeading : .bottomLeading) { tail }
            .shadow(color: .black.opacity(0.24), radius: 23, x: 0, y: 16)
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.95)
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : (tailEdge == .top ? -7 : 7))
            .onAppear {
                guard !reduceMotion else { hasAppeared = true; return }
                withAnimation(.easeOut(duration: Theme.Motion.popover)) { hasAppeared = true }
            }
    }

    private var tail: some View {
        Rectangle()
            .fill(Theme.Colors.surface)
            .frame(width: 12, height: 12)
            .overlay(Rectangle().strokeBorder(Theme.Colors.stroke, lineWidth: 0.5))
            .rotationEffect(.degrees(45))
            .offset(x: tailOffset, y: tailEdge == .top ? -6 : 6)
    }
}

#Preview("PopoverChrome") {
    PopoverChrome(width: 260) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Popover content").themeFont(.bodyStrong)
            Text("Any content composed by the caller.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(8)
    }
    .padding(60)
    .background(Theme.Colors.background)
}

/// Shared sheet container — dim overlay, centred card, corner radius, shadow, and the fade +
/// rise + scale entrance (Reduce Motion: appears instantly).
struct SheetChrome<Content: View>: View {
    var width: CGFloat
    var topOffset: CGFloat = 52
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(hasAppeared || reduceMotion ? 0.22 : 0)
                .ignoresSafeArea()
            content()
                .frame(width: width)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                        .strokeBorder(Theme.Colors.stroke, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.34), radius: 30, x: 0, y: 26)
                .padding(.top, topOffset)
                .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.965)
                .opacity(hasAppeared || reduceMotion ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 14)
        }
        .onAppear {
            guard !reduceMotion else { hasAppeared = true; return }
            withAnimation(.easeOut(duration: Theme.Motion.sheet)) { hasAppeared = true }
        }
    }
}

#Preview("SheetChrome") {
    SheetChrome(width: 420) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sheet title").themeFont(.sheetTitle)
            Text("Sheet content composed by the caller.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(20)
    }
    .frame(width: 700, height: 500)
    .background(Theme.Colors.background)
}

/// Shared update-banner container — full-width strip under the titlebar, bottom hairline, and
/// the slide-down entrance (Reduce Motion: appears instantly, no slide).
struct UpdateBannerChrome<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        content()
            .padding(.vertical, 9)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.accent.opacity(0.09))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Colors.hairline).frame(height: 0.5)
            }
            .offset(y: hasAppeared || reduceMotion ? 0 : -40)
            .onAppear {
                guard !reduceMotion else { hasAppeared = true; return }
                withAnimation(.easeOut(duration: Theme.Motion.banner).delay(0.15)) { hasAppeared = true }
            }
    }
}

#Preview("UpdateBannerChrome") {
    UpdateBannerChrome {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.Colors.accent)
            Text("A newer version v1.4 is available").themeFont(.body13)
            Spacer()
            LinkButton(title: "See what changed", action: {})
            PrimaryButton(title: "Update", action: {})
        }
    }
    .frame(width: 700)
    .background(Theme.Colors.surface)
}

// MARK: - Dark-mode previews
//
// Chrome (bg/surface/stroke/shadow) and the `#3a3a3c` SecondaryButton pair are exercised here
// rather than as individual per-component twins, since three of these are full-bleed dim/overlay
// containers that don't compose into one small gallery.

#Preview("PopoverChrome – Dark") {
    PopoverChrome(width: 260) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Popover content").themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
            Text("Any content composed by the caller.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(8)
    }
    .padding(60)
    .background(Theme.Colors.background)
    .preferredColorScheme(.dark)
}

#Preview("SheetChrome – Dark") {
    SheetChrome(width: 420) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sheet title").themeFont(.sheetTitle).foregroundStyle(Theme.Colors.text)
            Text("Sheet content composed by the caller.").themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(20)
    }
    .frame(width: 700, height: 500)
    .background(Theme.Colors.background)
    .preferredColorScheme(.dark)
}

#Preview("UpdateBannerChrome – Dark") {
    UpdateBannerChrome {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.Colors.accent)
            Text("A newer version v1.4 is available").themeFont(.body13).foregroundStyle(Theme.Colors.text)
            Spacer()
            LinkButton(title: "See what changed", action: {})
            PrimaryButton(title: "Update", action: {})
        }
    }
    .frame(width: 700)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

/// Every remaining component, once, in dark mode — backs the file-top map's "12 Dark …
/// exercises every token's dark variant through the components above" claim (dark `background`
/// #1c1c1e, `surface` #242426, `accent` #0a84ff, `success` #32d74b, the asymmetric `fill`, and
/// `SecondaryButton`'s local `#3a3a3c`).
#Preview("Dark gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                VerbChip(title: "Compress", suffix: "Balanced", isOn: true, icon: Image(systemName: "arrow.down.right.and.arrow.up.left"), toggle: {}, openOptions: {})
                VerbChip(title: "OCR", suffix: nil, isOn: false, icon: Image(systemName: "doc.text.magnifyingglass"), toggle: {})
            }
            HStack(spacing: 20) {
                StatusIndicator(kind: .finished)
                StatusIndicator(kind: .active(0.6))
                StatusIndicator(kind: .queued)
                StatusIndicator(kind: .unchanged)
                StatusIndicator(kind: .warn)
            }
            CapsuleProgressBar(fraction: 0.52).frame(width: 300)
            HStack(spacing: 8) {
                OptionCard(title: "Smallest", value: "6.2 MB", caption: "4.2 MB less", captionTone: .success, isSelected: false, action: {})
                OptionCard(title: "High quality", value: "23.0 MB", caption: "for printing", captionTone: .plain, isSelected: true, action: {})
            }
            HStack(spacing: 10) {
                CapsuleBadge(text: "3 versions", tone: .muted, icon: Image(systemName: "square.3.layers.3d"))
                CapsuleBadge(text: "3 versions", tone: .accent, icon: Image(systemName: "square.3.layers.3d"))
            }
            QueueRow(
                name: "Scanned-Contract.pdf", meta: "Rebuilt and searchable · 78% smaller",
                onOpen: {}, versionsCapsuleTitle: "3 versions", onVersionsCapsule: {}
            ) {
                HStack(spacing: 9) {
                    Text("4.1 MB").themeFont(.rowName).foregroundStyle(Theme.Colors.text)
                    StatusIndicator(kind: .finished)
                }
            }
            .frame(width: 560)
            BatchCard(icon: .warn, title: "4 of 5 files in Invoices", subtitle: "11:05 · one was password-locked",
                      trailingLink: (title: "Open folder", action: {}), action: {})
                .frame(width: 480)
            HStack(alignment: .top, spacing: 14) {
                VariantCard(title: "Rebuilt in layers", badgeText: "BEST FOR SCANS", badgeIsAccent: true,
                            sizeText: "4.1 MB", percentText: "78% smaller",
                            explanation: "Letters are traced and stay crisp at any zoom.",
                            previewURL: nil, isSelected: true)
            }
            .frame(width: 300)
            HStack(spacing: 10) {
                SecondaryButton(title: "Show in Finder", icon: Image(systemName: "folder"), action: {})
                SecondaryButton(title: "Cancel", action: {})
            }
            SegmentedRow(options: ["Fast", "Accurate"], selection: .constant(1)).frame(width: 200)
            DropdownRow(label: "Language on the page", options: ["English", "German"], selection: .constant("English")).frame(width: 260)
            ToggleRow(title: "Read the text (OCR)", stateLine: "English · Accurate", isOn: .constant(true)).frame(width: 260)
            RadioRow(title: "Rebuilt · 4.1 MB", subtitle: "In use. Text sharp, paper texture smoothed.", isSelected: true, subtitleTone: .accent, action: {})
                .frame(width: 300)
            CheckRow(title: "Annual-Report-2025.pdf", isChecked: .constant(true)).frame(width: 260)
        }
        .padding(24)
    }
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - Shared row helpers

/// Backs `QueueRow`'s click-to-open — mirrors `Components.swift`'s `RowOpenModifier` for
/// `FileRow`, duplicated rather than shared across files because `FileRow` predates the
/// redesign and is slated for deletion in Phase I, not a dependency this task should introduce.
private struct RowOpenModifier: ViewModifier {
    let onOpen: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpen {
            content.onTapGesture(perform: onOpen).pointingHandCursor().help("Open this PDF")
        } else {
            content
        }
    }
}
