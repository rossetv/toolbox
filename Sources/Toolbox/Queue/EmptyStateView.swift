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

    /// Pointer position normalised to ±1 from the centre of the whole centred content area (the
    /// handoff's `[data-parallax-stage]`), `nil` while the pointer is away. Every parallax layer
    /// is a pure function of this — so "at rest" is one state, not three.
    @State private var pointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                stage(size: geo.size)
            }

            if !history.batches.isEmpty {
                Divider()
                historyStrip
            }
        }
        .background(Theme.Colors.surface)
    }

    private func stage(size: CGSize) -> some View {
        VStack(spacing: 18) {
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
            switch phase {
            case .active(let location):
                guard !reduceMotion else { return }
                // ~90ms follow (spec §8) — near-immediate, not the exit-only settle spring.
                withAnimation(.easeOut(duration: 0.09)) { pointer = Self.normalise(location, in: size) }
            case .ended:
                // Deliberately not gated on Reduce Motion: turning it on mid-hover must still
                // let the icon come to rest rather than freeze mid-tilt.
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { pointer = nil }
            }
        }
    }

    /// Real app icon (matches `AboutView`'s own `NSApp.applicationIconImage` source) leaning
    /// towards the pointer, over an accent glow that slides the opposite way and under a
    /// specular sheen that follows it — the handoff's three `[data-parallax-*]` layers (spec §9:
    /// static under Reduce Motion, which simply leaves `pointer` at `nil`).
    ///
    /// Glow and sheen are attached *outside* the tilt so they stay flat, exactly as the
    /// handoff's siblings-in-a-perspective-box markup has them, and via `background`/`overlay`
    /// so the 104px glow can overflow without widening the 76px layout slot and pushing the
    /// stack's 18px gaps apart.
    private var icon: some View {
        let p = pointer ?? .zero
        return Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 76, height: 76)
            .scaleEffect(pointer == nil ? 1 : 1.05)
            .modifier(PointerTilt(dx: p.x, dy: p.y))
            .background {
                Circle()
                    .fill(RadialGradient(
                        colors: [Theme.Colors.accent.opacity(0.26), Theme.Colors.accent.opacity(0)],
                        center: .center,
                        // 66% of the CSS gradient's farthest-corner radius (52√2) on a 104px box.
                        startRadius: 0, endRadius: 48.54
                    ))
                    .frame(width: 104, height: 104)
                    .scaleEffect(1 + abs(p.x) * 0.12)
                    // Resting centre sits at 58% of the icon box — 6.08px below its middle.
                    .offset(x: -p.x * 16, y: 6.08 - p.y * 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(
                        stops: [.init(color: .white.opacity(0.6), location: 0),
                                .init(color: .white.opacity(0), location: 0.48)],
                        // The handoff's 125° gradient line across the 76px square.
                        startPoint: UnitPoint(x: -0.071, y: 0.100),
                        endPoint: UnitPoint(x: 1.071, y: 0.900)
                    ))
                    .opacity(pointer == nil ? 0 : 0.16 + min(1, abs(p.x) + abs(p.y)) * 0.42)
                    .offset(x: p.x * 22, y: p.y * 16)
            }
            // Decorative: the headline right below it already says "Drop PDFs to begin" —
            // VoiceOver gains nothing from a second announcement of the app icon.
            .accessibilityHidden(true)
    }

    /// Pointer offset from the stage centre, ±1 at the edges — the handoff's own normalisation,
    /// clamped because `onContinuousHover` can report a location just outside the bounds.
    static func normalise(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(1, max(-1, (location.x - size.width / 2) / (size.width / 2))),
                       y: min(1, max(-1, (location.y - size.height / 2) / (size.height / 2))))
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

    /// "14:22 · 21.2 MB smaller" for a clean run; "11:05 · one was password-locked" for a batch
    /// with a problem row (screen 01, F6b's `failureNote`) — falls back to a generic line only for
    /// a batch recorded before `failureNote` existed (on-disk schema predates F6b).
    static func subtitle(for batch: HistoryBatch) -> String {
        let time = batch.date.formatted(date: .omitted, time: .shortened)
        if let note = batch.failureNote { return "\(time) · \(note)" }
        if batch.problem { return "\(time) · needs attention" }
        if batch.savedBytes > 0 { return "\(time) · \(QueueByteFormat.string(batch.savedBytes)) smaller" }
        if batch.searchableCount > 0 { return "\(time) · made searchable" }
        return "\(time) · no change"
    }

    private func openFolder(_ batch: HistoryBatch) {
        NSWorkspace.shared.activateFileViewerSelecting([batch.folderURL])
    }
}

/// The handoff's `[data-parallax-icon]` transform, reproduced exactly: `rotateX(-dy·11°)
/// rotateY(dx·13°) translate3d(dx·7px, dy·7px, 0)` inside a **700px-perspective** container.
///
/// Spec §7 names `rotation3DEffect`; this composes the same rotation directly because
/// `rotation3DEffect`'s `perspective` argument has no documented unit — there is no value that
/// provably corresponds to the handoff's `perspective:700px`, and chaining two of them applies
/// two separate projections, which is what read as a shear. `m34 = -1/700` is the same number
/// the CSS states, and it is the near/far foreshortening that makes the tilt read as depth: the
/// two vertical edges of the 76px icon differ by ~1.8px at full 13° yaw.
private struct PointerTilt: GeometryEffect {
    var dx: Double
    var dy: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(dx, dy) }
        set { (dx, dy) = (newValue.first, newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Each `CATransform3D*` call prepends, so the applied order is translate → rotateY →
        // rotateX → perspective: the CSS transform list read right to left.
        var t = CATransform3DIdentity
        t.m34 = -1 / 700
        t = CATransform3DRotate(t, -dy * 11 * .pi / 180, 1, 0, 0)
        t = CATransform3DRotate(t, dx * 13 * .pi / 180, 0, 1, 0)
        t = CATransform3DTranslate(t, dx * 7, dy * 7, 0)
        // CSS `transform-origin: 50% 50%`: rotate about the icon's middle, not its top-left.
        let toCentre = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(toCentre)
            .concatenating(ProjectionTransform(t))
            .concatenating(ProjectionTransform(toCentre.inverted()))
    }
}

#Preview("Empty – no history") {
    EmptyStateView(history: HistoryStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-preview-\(UUID().uuidString)")), onChooseFiles: {})
        .frame(width: 900, height: 640)
}
