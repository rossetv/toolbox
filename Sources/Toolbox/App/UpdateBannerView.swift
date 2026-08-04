// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The update banner (design screen 11): a strip under the titlebar carrying the new version,
/// a link to the release notes, the Update button — which performs the whole self-update
/// (`SelfUpdater`, spec §6.10) — and a × that dismisses this version for good.
///
/// Dismissal is PER VERSION: `bannerDismissed` holds the version the user waved away, so the
/// next release raises the banner again. `dismissedVersion`'s `@AppStorage` wrapper is what
/// invalidates the view the moment × writes — a static `UserDefaults` read would register no
/// SwiftUI dependency.
struct UpdateBannerView: View {
    private static let dismissKey = "bannerDismissed"

    /// Copy pinned by spec §6.10's "after the current batch finishes" — two readers, one string.
    private static let blockedLine = "Toolbox will update after the current batch finishes."

    let release: UpdateChecker.Release
    /// Whether a batch is in flight, as a VALUE. `SelfUpdater` holds the same fact as an
    /// `isBusy` closure, but calling a closure registers no SwiftUI dependency — the button
    /// would stay live-looking until something unrelated redrew the banner.
    let isRunning: Bool
    @ObservedObject private var updater: SelfUpdater
    @AppStorage(UpdateBannerView.dismissKey) private var dismissedVersion: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringDismiss = false

    init(release: UpdateChecker.Release, updater: SelfUpdater, isRunning: Bool,
         store: UserDefaults = .standard) {
        self.release = release
        self.isRunning = isRunning
        _updater = ObservedObject(wrappedValue: updater)
        _dismissedVersion = AppStorage(wrappedValue: "", Self.dismissKey, store: store)
    }

    /// Whether THIS release's banner has been dismissed — the exact comparison `body` uses to
    /// decide whether to render at all, exposed so tests can drive the real path instead of a
    /// separate re-implementation of the rule.
    var isDismissed: Bool { dismissedVersion == release.version }

    /// Dismiss this version's banner. (`@AppStorage`'s setter is nonmutating.)
    func dismiss() { dismissedVersion = release.version }

    var body: some View {
        if !isDismissed {
            UpdateBannerChrome {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.Colors.accent)
                    Text(headline)
                        .themeFont(.body13)
                        .foregroundStyle(Theme.Colors.text)
                        .fixedSize()
                    LinkButton(title: "See what changed") {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                    if let status {
                        Text(status.text)
                            .themeFont(.caption)
                            .foregroundStyle(status.isError ? Theme.Colors.danger : Theme.Colors.textSecondary)
                            .lineLimit(2)
                            .help(status.text)
                    }
                    Spacer(minLength: Theme.Spacing.small)
                    ZStack {
                        // Invisible sizer: the banner's height is the button's in EVERY phase,
                        // so the button→bar swap never changes it — the bar + caption alone are
                        // shorter and the whole strip would jump on click.
                        PrimaryButton(title: "Update", isEnabled: false, compact: true, action: {}).hidden()
                        if let progress = activeProgress {
                            progressGroup(progress)
                                .transition(entrance)
                        } else {
                            PrimaryButton(title: buttonTitle, isEnabled: isButtonEnabled,
                                          compact: true, action: buttonAction)
                                .transition(entrance)
                        }
                    }
                    dismissButton
                }
                // Keyed on the stage LABEL, not the phase: the label changes once per stage,
                // so the button↔bar swap and stage renames animate while the per-percent
                // fraction ticks stay with the bar's own 0.2s fill animation.
                .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: activeProgress?.label)
            }
        }
    }

    /// Button → progress-group swap: a small fade + settle (DESIGN.md §8's un-tokenised
    /// one-shot transforms). Under Reduce Motion the driving animation below is nil, so the
    /// swap is a hard cut — this transition simply never rides.
    private var entrance: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.92))
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isHoveringDismiss ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isHoveringDismiss ? Theme.Colors.fill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .continuousHover($isHoveringDismiss)
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHoveringDismiss)
        .pointingHandCursor()
        .accessibilityLabel("Dismiss this update")
        .help("Don't show this version again")
    }

    // MARK: - Phase → chrome

    /// The banner's leading line: what is available when resting, what is HAPPENING while the
    /// update runs — the stage group carries the detail, this carries the intent, so a glance
    /// mid-update never reads as "still waiting for me to click".
    private var headline: String { Self.headline(for: updater.phase, version: release.version) }

    /// The phase→chrome mappings below are pure statics over `Phase`, with instance wrappers,
    /// so each mapping can be asserted directly for every phase (spec §11) without driving a
    /// real update into that phase — `Phase` is `private(set)` on the updater, deliberately.
    static func headline(for phase: SelfUpdater.Phase, version: String) -> String {
        activeProgress(for: phase) == nil
            ? "A newer version v\(version) is available"
            : "Updating to v\(version)…"
    }

    /// The stage label, bar fraction and whole-percent readout while an update is actually in
    /// flight; nil in every resting phase (which render the button instead). A nil FRACTION
    /// draws no bar at all: it means no honest fraction exists yet — the download hasn't
    /// received its first percent, or the server declared no Content-Length — and an empty
    /// track sitting dead beside "Downloading…" is exactly the hung look this UI replaces.
    /// Verify/install/restart hold the bar full rather than emptying it; with motion on, the
    /// sweep and cap glow keep it visibly alive (under Reduce Motion it is a static full bar
    /// and the stage label alone carries the state — §8's carve-out is for real-progress
    /// fills, never decoration).
    var activeProgress: (label: String, fraction: Double?, percent: Int?)? {
        Self.activeProgress(for: updater.phase)
    }

    static func activeProgress(for phase: SelfUpdater.Phase)
        -> (label: String, fraction: Double?, percent: Int?)? {
        switch phase {
        case .downloading(let fraction):
            return fraction > 0
                ? ("Downloading…", fraction, Int((fraction * 100).rounded()))
                : ("Downloading…", nil, nil)
        case .verifying: return ("Verifying…", 1, nil)
        case .installing: return ("Installing…", 1, nil)
        case .relaunching: return ("Restarting…", 1, nil)
        case .idle, .blockedByRun, .degradedToReleasePage, .failed: return nil
        }
    }

    private func progressGroup(_ progress: (label: String, fraction: Double?, percent: Int?)) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            ZStack(alignment: .trailing) {
                // Invisible sizer at the widest readout, so the label's width never changes
                // as the percent gains digits — without it every 9%→10% tick shoves the
                // whole trailing cluster sideways.
                Text("Downloading… 100%").themeFont(.caption).monospacedDigit().hidden()
                Text(progress.percent.map { "\(progress.label) \($0)%" } ?? progress.label)
                    .themeFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .fixedSize()
            if let fraction = progress.fraction {
                CapsuleProgressBar(fraction: fraction)
                    .frame(width: 150)
            }
        }
        .accessibilityElement(children: .combine)
        // The bar's own value would announce "100 percent" through Verifying/Installing/
        // Restarting — a completion claim for stages with no measurable fraction. The stage
        // label is the truth; the percent joins it only while one exists.
        .accessibilityValue(progress.percent.map { "\($0) percent" } ?? "")
    }

    private var buttonTitle: String { Self.buttonTitle(for: updater.phase) }

    static func buttonTitle(for phase: SelfUpdater.Phase) -> String {
        switch phase {
        // "Download…", not "Update": this install cannot be replaced in place, so the button
        // opens the release page — promising an in-app update it can't deliver would be a lie,
        // and the trailing ellipsis is the macOS convention for "leads somewhere else".
        case .degradedToReleasePage: return "Download…"
        case .idle, .blockedByRun, .failed: return "Update"
        // Unreachable while `activeProgress` maps every active phase to the progress group —
        // exhaustive so a future Phase case breaks the build here instead of silently
        // rendering "Update" mid-update.
        case .downloading, .verifying, .installing, .relaunching: return "Update"
        }
    }

    /// Internal, not private, so the disabled-while-running state can be asserted directly
    /// (spec §11) — as `isDismissed` is, for the same reason.
    var isButtonEnabled: Bool {
        // A swap mid-batch would pull the bundled gs out from under the running jobs, so the
        // button is dead for the whole run, not merely refused on the click (the caption says
        // so). `.blockedByRun` below stays live all the same: it is what a click that raced the
        // run starting lands on, and `update(release:)`'s own `isBusy` check remains the
        // authority — this only stops the user reaching it.
        guard !isRunning else { return false }
        switch updater.phase {
        case .blockedByRun, .downloading, .verifying, .installing, .relaunching: return false
        case .idle, .failed, .degradedToReleasePage: return true
        }
    }

    /// The line beside the headline: why the button is disabled, why it degraded, or what went
    /// wrong. Nil while the update is simply running — the button's own label carries that.
    /// Internal for the same reason as `isButtonEnabled`. Only the idle case consults
    /// `isRunning`: a batch started mid-download must not replace "Downloading…"'s silence with
    /// a promise to start later, and a failure line outranks it.
    var status: (text: String, isError: Bool)? {
        switch updater.phase {
        case .idle:
            return isRunning ? (Self.blockedLine, false) : nil
        case .blockedByRun:
            return (Self.blockedLine, false)
        case .degradedToReleasePage(let reason):
            return (reason, false)
        case .failed(let message, _):
            return (message, true)
        case .downloading, .verifying, .installing, .relaunching:
            return nil
        }
    }

    private func buttonAction() {
        // Degraded: there is nothing to install here, so the button is the release page.
        if case .degradedToReleasePage = updater.phase {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        Task { await updater.update(release: release) }
    }
}

#Preview("UpdateBannerView") {
    UpdateBannerView(
        release: UpdateChecker.Release(
            version: "1.4",
            pageURL: URL(string: "https://github.com/rossetv/toolbox/releases/tag/v1.4")!,
            dmgURL: nil),
        updater: SelfUpdater(isBusy: { false }),
        isRunning: false,
        store: UserDefaults(suiteName: "toolbox.preview.banner") ?? .standard)
    .frame(width: 900)
    .background(Theme.Colors.surface)
}
