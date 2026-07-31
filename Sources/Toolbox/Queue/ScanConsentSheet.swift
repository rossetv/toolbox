// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI

/// The scan-rebuild consent sheet (handoff screen 09), surfaced one at a time (FIFO) as each
/// rebuilt scan's delivery completes (spec §7): both variants are already on disk, and this
/// choice is an instant switch between them, never a re-run — "Nothing is decided yet" stays
/// honest right up to the button press.
struct ScanConsentSheet: View {
    @ObservedObject var model: QueueViewModel
    let jobID: ToolJob.ID

    var body: some View {
        Group {
            // The queued id can be withdrawn under an open sheet (a re-run replaces the pair, or
            // the row leaves the queue) — render nothing rather than describe a pair that no
            // longer exists.
            if let job = model.jobs.first(where: { $0.id == jobID }),
               let pair = Self.resolvedPair(row: model.versions(for: job)) {
                content(job: job, pair: pair)
            }
        }
    }

    private func content(job: ToolJob, pair: (mrc: FileVersion, plain: FileVersion, shipped: FileVersion)) -> some View {
        SheetChrome(width: 700) {
            VStack(alignment: .leading, spacing: 16) {
                SheetTitleRow(title: "\(job.url.lastPathComponent) came out two ways",
                             caption: "Both are on disk. Nothing is decided yet.")
                HStack(alignment: .top, spacing: 14) {
                    variantCard(pair.mrc, isShipped: pair.shipped.variant == .mrc, originalSize: originalBytes(job))
                    variantCard(pair.plain, isShipped: pair.shipped.variant == .plain, originalSize: originalBytes(job))
                }
                HStack {
                    Toggle(isOn: $model.rebuildWithoutAsking) {
                        Text("Rebuild scans from now on without asking").themeFont(.body13)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.Colors.accent)
                    Spacer(minLength: Theme.Spacing.small)
                    LinkButton(title: "Open both in Preview") {
                        NSWorkspace.shared.open(pair.mrc.url)
                        NSWorkspace.shared.open(pair.plain.url)
                    }
                }
                Divider()
                HStack {
                    Text("The one you don't keep is deleted when you quit.")
                        .themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
                    Spacer(minLength: Theme.Spacing.small)
                    SecondaryButton(title: "Keep photographs") {
                        Task { await model.resolveConsent(jobID, keepRebuilt: false) }
                    }
                    PrimaryButton(title: "Keep rebuilt") {
                        Task { await model.resolveConsent(jobID, keepRebuilt: true) }
                    }
                }
            }
            .padding(20)
        }
    }

    private func originalBytes(_ job: ToolJob) -> Int {
        model.versions(for: job)?.originalBytes ?? 0
    }

    private func variantCard(_ version: FileVersion, isShipped: Bool, originalSize: Int) -> some View {
        let badge = Self.variantBadge(version.variant)
        return VariantCard(
            title: Self.variantTitle(version.variant),
            badgeText: badge.text,
            badgeIsAccent: badge.isAccent,
            sizeText: QueueByteFormat.string(version.bytes),
            percentText: Self.percentText(bytes: version.bytes, originalBytes: originalSize),
            explanation: Self.variantExplanation(version.variant),
            previewURL: version.url,
            isSelected: isShipped
        )
    }

    // MARK: pure logic (PopoverLogicTests)

    /// The row's rebuilt/plain pair, and which of the two is currently shipped — `nil` unless the
    /// row still holds exactly the {.mrc, .plain} pair `surfaceConsent` gates on (spec §7): a
    /// withdrawn consent, a switch failure, or a row with no versions at all all resolve to nil.
    static func resolvedPair(row: RowVersions?) -> (mrc: FileVersion, plain: FileVersion, shipped: FileVersion)? {
        guard let row, let shipped = row.shipped, let runnerUp = row.runnerUp else { return nil }
        let mrc = shipped.variant == .mrc ? shipped : (runnerUp.variant == .mrc ? runnerUp : nil)
        let plain = shipped.variant == .plain ? shipped : (runnerUp.variant == .plain ? runnerUp : nil)
        guard let mrc, let plain else { return nil }
        return (mrc, plain, shipped)
    }

    /// Percentages never lie (spec §7): a variant that grew past the original states so, rather
    /// than printing a negative "smaller" figure.
    static func percentText(bytes: Int, originalBytes: Int) -> String {
        guard originalBytes > 0, bytes < originalBytes else {
            guard originalBytes > 0, bytes > originalBytes else { return "same size" }
            let percent = Int((( Double(bytes) / Double(originalBytes) - 1) * 100).rounded())
            return "\(percent)% bigger"
        }
        let percent = Int(((1 - Double(bytes) / Double(originalBytes)) * 100).rounded())
        return "\(percent)% smaller"
    }

    /// Defensive over all three `EngineVariant` cases, even though `surfaceConsent` only ever
    /// pairs `{.mrc, .plain}` today — `.original` is exercised by `PopoverLogicTests` as a
    /// guarantee the copy never lies if this sheet's gate is ever loosened.
    static func variantTitle(_ variant: EngineVariant) -> String {
        switch variant {
        case .mrc: return "Rebuilt in layers"
        case .plain: return "Left as photographs"
        case .original: return "Untouched original"
        }
    }

    static func variantBadge(_ variant: EngineVariant) -> (text: String, isAccent: Bool) {
        switch variant {
        case .mrc: return ("BEST FOR SCANS", true)
        case .plain: return ("NOTHING REDRAWN", false)
        case .original: return ("UNCHANGED", false)
        }
    }

    static func variantExplanation(_ variant: EngineVariant) -> String {
        switch variant {
        case .mrc:
            return "Letters are traced and stay crisp at any zoom. The paper behind them is flattened, "
                 + "so grain, shadows and coffee rings disappear."
        case .plain:
            return "Each page stays a picture of the paper, just lighter. Choose this when the sheet "
                 + "itself is evidence — signatures, stamps, handwriting."
        case .original:
            return "Exactly the file you started with, unchanged."
        }
    }

}

#Preview("ScanConsentSheet") {
    let model = QueueViewModel(engine: nil)
    return ScanConsentSheet(model: model, jobID: UUID())
        .frame(width: 900, height: 600)
        .background(Theme.Colors.background)
}
