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
/// next release raises the banner again. Both readers — the wrapper here and the
/// `isDismissed(version:in:)` seam — are pinned to the same key and the same store: a static
/// `UserDefaults` read registers no SwiftUI dependency, so the wrapper is what invalidates the
/// view the moment × writes.
struct UpdateBannerView: View {
    private static let dismissKey = "bannerDismissed"

    let release: UpdateChecker.Release
    @ObservedObject private var updater: SelfUpdater
    @AppStorage(UpdateBannerView.dismissKey) private var dismissedVersion: String = ""

    init(release: UpdateChecker.Release, updater: SelfUpdater, store: UserDefaults = .standard) {
        self.release = release
        _updater = ObservedObject(wrappedValue: updater)
        _dismissedVersion = AppStorage(wrappedValue: "", Self.dismissKey, store: store)
    }

    /// Whether the banner for `version` has been dismissed. Same key and store as the wrapper.
    static func isDismissed(version: String, in store: UserDefaults) -> Bool {
        store.string(forKey: dismissKey) == version
    }

    /// Dismiss this version's banner. (`@AppStorage`'s setter is nonmutating.)
    func dismiss() { dismissedVersion = release.version }

    var body: some View {
        if dismissedVersion != release.version {
            UpdateBannerChrome {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.Colors.accent)
                    Text("A newer version v\(release.version) is available")
                        .themeFont(.body13)
                        .foregroundStyle(Theme.Colors.text)
                        .monospacedDigit()
                        .fixedSize()
                    if let status {
                        Text(status.text)
                            .themeFont(.caption)
                            .foregroundStyle(status.isError ? Theme.Colors.danger : Theme.Colors.textSecondary)
                            .lineLimit(2)
                            .help(status.text)
                    }
                    Spacer(minLength: Theme.Spacing.small)
                    LinkButton(title: "See what changed") {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                    PrimaryButton(title: buttonTitle, isEnabled: isButtonEnabled, action: buttonAction)
                    dismissButton
                }
            }
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .clearsClickFocus()
        .pointingHandCursor()
        .accessibilityLabel("Dismiss this update")
        .help("Don't show this version again")
    }

    // MARK: - Phase → chrome

    private var buttonTitle: String {
        switch updater.phase {
        case .idle, .blockedByRun, .failed: return "Update"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .installing: return "Installing…"
        case .relaunching: return "Restarting…"
        case .degradedToReleasePage: return "See the release page"
        }
    }

    private var isButtonEnabled: Bool {
        switch updater.phase {
        // A swap mid-batch would pull the bundled gs out from under the running jobs, so the
        // button stays disabled until the batch finishes (the caption says so).
        case .blockedByRun, .downloading, .verifying, .installing, .relaunching: return false
        case .idle, .failed, .degradedToReleasePage: return true
        }
    }

    /// The line beside the headline: why the button is disabled, why it degraded, or what went
    /// wrong. Nil while the update is simply running — the button's own label carries that.
    private var status: (text: String, isError: Bool)? {
        switch updater.phase {
        case .blockedByRun:
            return ("Toolbox will update after the current batch finishes.", false)
        case .degradedToReleasePage(let reason):
            return (reason, false)
        case .failed(let message, _):
            return (message, true)
        case .idle, .downloading, .verifying, .installing, .relaunching:
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
        store: UserDefaults(suiteName: "toolbox.preview.banner") ?? .standard)
    .frame(width: 900)
    .background(Theme.Colors.surface)
}
