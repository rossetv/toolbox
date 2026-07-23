// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI
import UniformTypeIdentifiers

/// The Compress tool view — batch drop/pick, preset picker, optional output-folder picker,
/// per-file rows (estimate → live progress → real before/after), cancel. Built from the design
/// system: `ToolHeader`, `DropZone`, `FileRow`, `SegmentedPreset`, `PrimaryButton`.
struct CompressView: View {
    @StateObject private var model = CompressViewModel()
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var isChoosingOutputFolder = false

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                systemImage: Tool.compress.systemImage,
                title: "Compress",
                subtitle: "Shrink large PDFs. Text and vectors stay sharp; images are re-encoded."
            )
            loadErrorBanner
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footerBar
        }
        .background(Theme.Colors.surface)
        .navigationTitle("Compress")
        .onDrop(of: [.pdf], isTargeted: $isTargeted) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .overlay { dropHighlight }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .fileImporter(isPresented: $isChoosingOutputFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.outputFolder = url }
        }
    }

    // MARK: sections

    @ViewBuilder
    private var content: some View {
        if model.jobs.isEmpty {
            DropZone(
                isTargeted: isTargeted,
                title: "Drop PDFs here",
                subtitle: "or add them manually · batch supported",
                buttonTitle: "Choose Files…"
            ) { isImporting = true }
                .padding(Theme.Spacing.large)
        } else {
            queue
        }
    }

    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                summaryRow
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(model.jobs) { job in
                        FileRow(name: job.url.lastPathComponent,
                                meta: meta(for: job),
                                status: status(for: job))
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel("Quality")
                    SegmentedPreset(options: presetOptions,
                                    selection: presetSelection,
                                    isEnabled: !model.isRunning)
                }
                outputFolderRow
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(queueSummary).themeFont(.captionBold).foregroundStyle(Theme.Colors.text)
            Spacer(minLength: Theme.Spacing.small)
            if !model.isRunning {
                LinkButton(title: "+ Add") { isImporting = true }
            }
            if hasFinishedJobs {
                LinkButton(title: "Clear finished") { model.clearFinished() }
            }
        }
    }

    private var outputFolderRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Save to").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            Text(model.outputFolder?.lastPathComponent ?? "Alongside originals")
                .themeFont(.captionBold)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.small)
            if model.outputFolder != nil {
                LinkButton(title: "Use original location") { model.outputFolder = nil }
            }
            LinkButton(title: "Change…") { isChoosingOutputFolder = true }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 4)
        .background(Theme.Colors.background,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.5 : 1)
    }

    private var footerBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(footerNote).themeFont(.caption).foregroundStyle(Theme.Colors.textTertiary)
            Spacer(minLength: Theme.Spacing.small)
            if model.isRunning {
                ProgressView().controlSize(.small)
                LinkButton(title: "Cancel") { model.cancel() }
            }
            PrimaryButton(title: actionTitle, isEnabled: model.canCompress) { model.compress() }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.surface)
    }

    /// A drop target is obvious in the empty state (the `DropZone` highlights itself); once the
    /// queue replaces it, this ring is the only thing telling you the pane still accepts files.
    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted, !model.jobs.isEmpty {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.accent, lineWidth: 2)
                .padding(2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var loadErrorBanner: some View {
        if let error = model.loadError {
            Label {
                Text(error).themeFont(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(.red.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(Theme.Spacing.medium)
        }
    }

    // MARK: job → row state

    /// Maps the queue's `JobState`/`JobOutcome` onto the presentational `FileRow.Status`.
    private func status(for job: ToolJob) -> FileRow.Status {
        switch job.state {
        case .queued:
            return .queued(detail: estimateText(for: job))
        case .analysing:
            return .analysing
        case .running(let fraction):
            return .inProgress(fraction: fraction > 0 ? fraction : nil)
        case .done(let outcome):
            switch outcome {
            case .compressed(let before, let after):
                return .done(originalBytes: before, newBytes: after)
            case .noGain:
                return .unchanged("Already optimised")
            case .ocrAdded, .alreadySearchable:
                return .succeeded("Done")
            }
        case .failed(let message):
            return .error(message)
        }
    }

    private func estimateText(for job: ToolJob) -> String {
        guard let estimate = job.estimate else { return "Queued" }
        // "~" marks a typical-range fallback (content type unknown/analysis timed out);
        // "≈" marks a real sample-based prediction for this file.
        let marker = estimate.isFallback ? "~" : "\u{2248}"
        return "\(marker)\(byteString(estimate.predictedBytes)) predicted"
    }

    private func meta(for job: ToolJob) -> String {
        inputSize(of: job).map(byteString) ?? job.url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: derived copy

    private var presetOptions: [SegmentedPresetOption] {
        // An exhaustive switch, so a new preset can't silently ship without its blurb. The
        // hints stay non-numeric on purpose: the presets' real DPI figures are retuned against
        // the corpus in Task S.2, and a hard-coded "~150 DPI" here would quietly go stale.
        CompressPreset.allCases.map { preset in
            switch preset {
            case .maximumQuality:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Light touch, keeps fine detail.",
                                             hint: "Highest image resolution")
            case .balanced:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Great size, near-original look.",
                                             hint: "Recommended for most PDFs")
            case .smallestSize:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Maximum shrink for email & upload.",
                                             hint: "Lowest image resolution")
            }
        }
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { model.preset.id },
            set: { if let preset = CompressPreset(rawValue: $0) { model.preset = preset } }
        )
    }

    private var queueSummary: String {
        let count = model.jobs.count
        let files = "\(count) file\(count == 1 ? "" : "s")"
        let total = model.jobs.compactMap(inputSize).reduce(0, +)
        return total > 0 ? "\(files) · \(byteString(total))" : files
    }

    private var actionTitle: String {
        let n = pendingCount
        return n > 0 ? "Compress \(n) PDF\(n == 1 ? "" : "s")" : "Compress"
    }

    private var footerNote: String {
        if model.isRunning {
            let current = min(finishedCount + 1, model.jobs.count)
            return "Compressing \(current) of \(model.jobs.count)…"
        }
        return savedSummary ?? "Originals are never modified."
    }

    /// The batch's headline result once a run has finished — total bytes saved across every
    /// file that actually shrank.
    private var savedSummary: String? {
        var before = 0
        var after = 0
        for job in model.jobs {
            if case .done(.compressed(let jobBefore, let jobAfter)) = job.state {
                before += jobBefore
                after += jobAfter
            }
        }
        guard before > after else { return nil }
        let percent = Int((1 - Double(after) / Double(before)) * 100)
        return "Saved \(byteString(before - after)) · \(percent)% smaller"
    }

    private var pendingCount: Int {
        model.jobs.filter { job in
            switch job.state {
            case .queued, .analysing: return true
            case .running, .done, .failed: return false
            }
        }.count
    }

    private var finishedCount: Int {
        model.jobs.filter { job in
            switch job.state {
            case .done, .failed: return true
            case .queued, .analysing, .running: return false
            }
        }.count
    }

    private var hasFinishedJobs: Bool { finishedCount > 0 }

    // MARK: helpers

    /// The input's size on disk. A local `URLResourceValues` read — cheap enough per render for
    /// a hand-sized queue, and it keeps the view model free of display-only bookkeeping.
    private func inputSize(of job: ToolJob) -> Int? {
        (try? job.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add([url]) }
            }
        }
    }
}

#Preview("Compress – Light") {
    CompressView()
        .frame(width: 720, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Compress – Dark") {
    CompressView()
        .frame(width: 720, height: 520)
        .preferredColorScheme(.dark)
}
