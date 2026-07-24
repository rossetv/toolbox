// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The Compress tool view — batch drop/pick, preset picker, optional output-folder picker,
/// per-file rows (estimate → live progress → real before/after), cancel. Built from the design
/// system: `ToolHeader`, `DropZone`, `FileRow`, `SegmentedPreset`, `PrimaryButton`.
struct CompressView: View {
    @StateObject private var model = CompressViewModel()
    @State private var isTargeted = false
    @State private var heavyPopoverJobID: ToolJob.ID?
    @State private var quickLookURL: URL?
    /// The pair Quick Look flips between with the ⇄ arrows (R11), frozen at the moment a preview
    /// opens. NEVER cleared, only overwritten by the next preview: deriving this from
    /// `heavyPopoverJobID` collapsed the collection 2→0 whenever the (transient) popover dismissed
    /// while the panel was alive, and `QLPreviewPanelController` traps on that KVO reload
    /// (`currentPreviewItemIndex`) — the field crash. Clearing when `quickLookURL` goes nil would
    /// reopen the same trap in the panel's animated-teardown window, so the stale pair is simply
    /// kept; it is two URLs.
    @State private var frozenQuickLookItems: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                systemImage: Tool.compress.systemImage,
                title: "Compress",
                subtitle: "Shrink large PDFs. Text and vectors stay sharp; images are re-encoded.",
                tint: Tool.compress.tint
            )
            loadErrorBanner
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footerBar
        }
        .background(Theme.Colors.surface)
        .animation(.easeInOut(duration: 0.2), value: model.isRunning)
        .animation(.easeInOut(duration: 0.2), value: model.allFinished)
        // `.fileURL`, not `.pdf`: a drag from Finder advertises `public.file-url`, so matching on
        // the PDF content type rejected every drop before this closure could run — the drop zone
        // looked live and did nothing. `add` still filters to local PDFs.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .overlay { dropHighlight }
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
            ) { model.add(FilePicker.choosePDFs()) }
                .padding(Theme.Spacing.large)
        } else {
            queue
        }
    }

    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                if model.isRunning {
                    runningBar
                } else if model.allFinished {
                    SuccessBanner(headline: savedHeadline, detail: savedDetail)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                summaryRow
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(model.jobs) { job in
                        FileRow(name: job.url.lastPathComponent,
                                meta: meta(for: job),
                                fileURL: job.url,
                                status: status(for: job),
                                onRemove: canRemove(job) ? { model.remove(job) } : nil,
                                onOpen: { open(job) },
                                onHeavyTap: { heavyPopoverJobID = job.id },
                                heavyPopoverPresented: isShowingHeavyPopover(for: job.id),
                                heavyPopoverContent: { AnyView(heavyPopover(for: job)) })
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
        .quickLookPreview($quickLookURL, in: frozenQuickLookItems)
    }

    @ViewBuilder
    private func heavyPopover(for job: ToolJob) -> some View {
        if let versions = model.heavyVersions(for: job) {
            HeavyCompressionPopover(
                versions: versions,
                originalBytes: originalBytes(for: job),
                // Request panel dismissal before the swap (SwiftUI dismisses asynchronously, so
                // a closing panel may still render one stale frame — accepted; the frozen items
                // collection is untouched, so the panel never sees a shrinking collection).
                onSwitch: {
                    quickLookURL = nil
                    model.switchVersion(for: job)
                    heavyPopoverJobID = nil
                },
                onPreview: { url in
                    frozenQuickLookItems = [versions.shippedURL, versions.runnerUpURL]
                    quickLookURL = url
                })
        }
    }

    private func isShowingHeavyPopover(for id: ToolJob.ID) -> Binding<Bool> {
        Binding(
            get: { heavyPopoverJobID == id },
            set: { isPresented in if !isPresented { heavyPopoverJobID = nil } }
        )
    }

    private func originalBytes(for job: ToolJob) -> Int {
        if case .done(.compressedHeavy(let before, _, _)) = job.state { return before }
        return 0
    }

    /// Batch progress with a live count, mirroring the mockup's "Compressing 2 of 3…" bar.
    private var runningBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            LinearProgress(fraction: overallProgress)
            Text("Compressing \(finishedCount + 1) of \(model.jobs.count)…")
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize()
            LinkButton(title: "Cancel") { model.cancel() }
        }
    }

    private var overallProgress: Double {
        guard !model.jobs.isEmpty else { return 0 }
        let total = model.jobs.reduce(0.0) { sum, job in
            switch job.state {
            case .done, .failed: return sum + 1
            case .running(let f): return sum + f
            default: return sum
            }
        }
        return total / Double(model.jobs.count)
    }

    private func canRemove(_ job: ToolJob) -> Bool {
        if case .queued = job.state { return !model.isRunning }
        return false
    }

    private var savedBytes: Int {
        model.jobs.reduce(0) { sum, job in
            guard let (before, after) = model.displayedSizes(for: job) else { return sum }
            return sum + max(0, before - after)
        }
    }

    private var savedHeadline: String { "Saved \(byteString(savedBytes))" }

    private var savedDetail: String {
        var before = 0, after = 0
        for job in model.jobs {
            if let (b, a) = model.displayedSizes(for: job) { before += b; after += a }
        }
        let pct = before > 0 ? Int(((Double(before - after) / Double(before)) * 100).rounded()) : 0
        let n = model.jobs.count
        return "\(n) PDF\(n == 1 ? "" : "s") · \(byteString(before)) → \(byteString(after)) · \(pct)% smaller"
    }

    private var summaryRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(queueSummary).themeFont(.captionBold).foregroundStyle(Theme.Colors.text)
            Spacer(minLength: Theme.Spacing.small)
            if !model.isRunning {
                LinkButton(title: "+ Add") { model.add(FilePicker.choosePDFs()) }
            }
            if hasFinishedJobs {
                LinkButton(title: "Clear finished") { model.clearFinished() }
            }
        }
    }

    /// How the output will be named. With a single file in the queue that is its real resulting
    /// filename, which is more use than a placeholder; with several, the pattern they all follow.
    private var outputNamePreview: String {
        if model.jobs.count == 1, let job = model.jobs.first {
            let base = job.url.deletingPathExtension().lastPathComponent
            return "as \(base)-compressed.pdf"
        }
        return "as <file>-compressed.pdf"
    }

    private func revealOutputs() {
        // Fall back to the originals' folder when nothing new was written (every file was
        // already optimised), so the button still does something sensible.
        let outputs = model.jobs.compactMap(\.resultURL)
        let urls = outputs.isEmpty ? model.jobs.map(\.url) : outputs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Open the compressed result if one was produced, otherwise the original.
    private func open(_ job: ToolJob) {
        NSWorkspace.shared.open(job.resultURL ?? job.url)
    }

    private var outputFolderRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Save to").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            Text(model.outputFolder?.lastPathComponent ?? "Alongside originals")
                .themeFont(.captionBold)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(outputNamePreview)
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.small)
            if model.outputFolder != nil {
                LinkButton(title: "Use original location") { model.outputFolder = nil }
            }
            LinkButton(title: "Change…") { if let f = FilePicker.chooseFolder() { model.outputFolder = f } }
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
            if model.allFinished {
                LinkButton(title: "Reveal in Finder ›") { revealOutputs() }
                Spacer(minLength: Theme.Spacing.small)
                PrimaryButton(title: "Compress More", isEnabled: true) {
                    model.add(FilePicker.choosePDFs())
                }
            } else {
                if model.isRunning { ProgressView().controlSize(.small) }
                PrimaryButton(title: actionTitle, isEnabled: model.canCompress) { model.compress() }
            }
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
            return .queued(detail: estimateText(for: job), savedPercent: predictedSaving(for: job))
        case .analysing:
            return .analysing
        case .running(let fraction):
            return .inProgress(fraction: fraction > 0 ? fraction : nil)
        case .done(let outcome):
            switch outcome {
            case .compressed(let before, let after):
                return .done(originalBytes: before, newBytes: after)
            case .compressedHeavy(let before, let after, _):
                guard let versions = model.heavyVersions(for: job) else {
                    return .done(originalBytes: before, newBytes: after)
                }
                return .doneHeavy(originalBytes: before, newBytes: versions.displayedBytes)
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
        // Show the predicted saving as well as the predicted size: a bare figure gives no sense
        // of whether the preset is worth choosing, which is the decision this line exists to serve.
        guard let original = inputSize(of: job), original > 0 else {
            return "\(marker)\(byteString(estimate.predictedBytes)) predicted"
        }
        guard original > estimate.predictedBytes else { return "\(marker)no saving predicted" }
        return "\(marker)\(byteString(estimate.predictedBytes)) predicted"
    }

    /// Predicted saving as a whole percent, shown as a badge beside the predicted size.
    private func predictedSaving(for job: ToolJob) -> Int? {
        guard let estimate = job.estimate,
              let original = inputSize(of: job), original > 0,
              original > estimate.predictedBytes else { return nil }
        let saved = original - estimate.predictedBytes
        return Int(((Double(saved) / Double(original)) * 100).rounded())
    }

    private func meta(for job: ToolJob) -> String {
        let size = inputSize(of: job).map(byteString)
        let pages = model.pageCount(for: job).map { "\($0) page\($0 == 1 ? "" : "s")" }
        return [size, pages].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: derived copy

    private var presetOptions: [SegmentedPresetOption] {
        // An exhaustive switch, so a new preset can't silently ship without its blurb. The hint
        // states the preset's real target DPI, read from the preset itself so it cannot go stale.
        CompressPreset.allCases.map { preset in
            switch preset {
            case .maximumQuality:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Light touch, keeps fine detail.",
                                             hint: "~\(preset.imageDPI) DPI images")
            case .balanced:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Great size, near-original look.",
                                             hint: "~\(preset.imageDPI) DPI images")
            case .smallestSize:
                return SegmentedPresetOption(id: preset.id, title: preset.title,
                                             subtitle: "Maximum shrink for email & upload.",
                                             hint: "~\(preset.imageDPI) DPI images")
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
            if let (jobBefore, jobAfter) = model.displayedSizes(for: job) {
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
