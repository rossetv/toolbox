// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

/// The window's bottom bar across every non-empty screen state: screen 03's estimate + Start,
/// screen 05's saved-so-far + Cancel, screen 06's save location + Show in Finder/Change
/// quality/Add More, screen 10's "files that failed…" + Add More.
struct QueueFooterView: View {
    @ObservedObject var model: QueueViewModel
    let state: QueueScreenState
    let onStart: () -> Void
    let onCancel: () -> Void
    let onShowInFinder: () -> Void
    let onChangeQuality: () -> Void
    let onAddMore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            leading
            Spacer(minLength: Theme.Spacing.small)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.surface)
    }

    @ViewBuilder
    private var leading: some View {
        switch state {
        case .empty:
            EmptyView()
        case .ready:
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.readyHeadline(model: model)).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text("Your originals stay exactly where they are.").themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .working:
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.workingHeadline(model: model)).themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                // D2's recorded copy divergence (spec §6.8): concurrency stayed P-core parallel,
                // so the handoff's "one core at a time" line would be false.
                Text("Toolbox works several files at once on your Mac's fastest cores.")
                    .themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .finished:
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved in \(Self.folderBreadcrumb(model: model))").themeFont(.bodyStrong).foregroundStyle(Theme.Colors.text)
                Text("Click any file to open it. Changed your mind? Pick a different quality.")
                    .themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
            }
        case .problems:
            Text("Files that failed were not touched at all.").themeFont(.meta).foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .empty:
            EmptyView()
        case .ready:
            PrimaryButton(title: Self.startTitle(model: model), isEnabled: model.canStart, action: onStart)
        case .working:
            SecondaryButton(title: "Cancel", action: onCancel)
        case .finished:
            HStack(spacing: Theme.Spacing.small) {
                SecondaryButton(title: "Show in Finder", icon: Image(systemName: "folder"), action: onShowInFinder)
                SecondaryButton(title: "Change quality", action: onChangeQuality)
                PrimaryButton(title: "Add More", action: onAddMore)
            }
        case .problems:
            PrimaryButton(title: "Add More", action: onAddMore)
        }
    }

    // MARK: pure, testable copy

    /// "48.2 MB → about 12.6 MB" from every queued row's own input size and estimate.
    static func readyHeadline(model: QueueViewModel) -> String {
        var before = 0, predicted = 0, counted = 0
        for job in model.jobs {
            guard let size = QueueByteFormat.size(of: job.url) else { continue }
            before += size
            if let estimate = job.estimate {
                predicted += estimate.predictedBytes
                counted += 1
            }
        }
        guard before > 0 else { return "Ready to start" }
        guard counted == model.jobs.count else { return "\(QueueByteFormat.string(before)) total" }
        return "\(QueueByteFormat.string(before)) \u{2192} about \(QueueByteFormat.string(predicted))"
    }

    static func startTitle(model: QueueViewModel) -> String {
        let queued = model.pendingCount, armed = model.armedCount
        if queued > 0, armed > 0 { return "Compress \(queued) \u{00B7} Recompress \(armed)" }
        if armed > 0 { return "Recompress \(armed) PDF\(armed == 1 ? "" : "s")" }
        return "Start"
    }

    /// "N MB saved so far" — never "0 MB saved" (spec §6.3's forbidden string): an all-OCR batch
    /// (or one still too early to have shipped a compressed row) reads the searchable count
    /// instead (`testAllOCRBatchFooterNeverSaysZeroSaved`).
    static func workingHeadline(model: QueueViewModel) -> String {
        let saved = model.batchProgress?.savedSoFarBytes ?? 0
        if saved > 0 { return "\(QueueByteFormat.string(saved)) saved so far" }
        let searchable = searchableCount(model)
        guard searchable > 0 else { return "Working…" }
        return "\(searchable) file\(searchable == 1 ? "" : "s") made searchable so far"
    }

    private static func searchableCount(_ model: QueueViewModel) -> Int {
        model.jobs.filter { model.versions(for: $0)?.searchableByCard[.shipped] == true }.count
    }

    /// The last two path components ("Documents › Contracts") of the save destination, or the
    /// first queued row's own folder when nothing was overridden — mirrors `HistoryStore`'s own
    /// nil-folder resolution (a batch with no destination delivers each file beside itself).
    static func folderBreadcrumb(model: QueueViewModel) -> String {
        let folder = model.outputFolder ?? model.jobs.first?.url.deletingLastPathComponent()
        guard let folder else { return "its original folder" }
        let components = folder.pathComponents.filter { $0 != "/" }
        let tail = components.suffix(2)
        return tail.isEmpty ? folder.lastPathComponent : tail.joined(separator: " \u{203A} ")
    }
}

#Preview("Footer – Ready") {
    QueueFooterView(model: QueueViewModel(), state: .ready,
                    onStart: {}, onCancel: {}, onShowInFinder: {}, onChangeQuality: {}, onAddMore: {})
        .frame(width: 900)
}
