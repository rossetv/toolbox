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
    /// Owned by `RootView`, not this view: the detail pane is rebuilt on every tool switch, and
    /// a view-owned `@StateObject` died with it — taking the finished batch, the runner-up
    /// references and any in-flight run's cancel handle along (review M9, reproduced live).
    @ObservedObject var model: CompressViewModel
    @State private var isTargeted = false
    @State private var heavyPopoverJobID: ToolJob.ID?
    @State private var quickLookURL: URL?
    /// The versions Quick Look flips between with the ⇄ arrows (R11), frozen at the moment a
    /// preview opens — two or three of them, per the row (R15). NEVER cleared, and only ever
    /// replaced through `freezeQuickLookItems`, which forbids the collection from shrinking:
    /// deriving this from `heavyPopoverJobID` collapsed it 2→0 whenever the (transient) popover
    /// dismissed while the panel was alive, and `QLPreviewPanelController` traps on that KVO
    /// reload (`currentPreviewItemIndex`) — the field crash. Clearing when `quickLookURL` goes nil
    /// would reopen the same trap in the panel's animated-teardown window, so the stale set is
    /// simply kept; it is at most three URLs.
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
        // Arming swaps the banner and every row's lead in one go — animated like the other state
        // changes, or the armed chrome would snap in while the finished chrome faded out.
        .animation(.easeInOut(duration: 0.2), value: model.armedCount)
        // `.fileURL`, not `.pdf`: a drag from Finder advertises `public.file-url`, so matching on
        // the PDF content type rejected every drop before this closure could run — the drop zone
        // looked live and did nothing. `add` still filters to local PDFs.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            // Refuse mid-run rather than swallow: `model.add` ignores files while a batch is in
            // flight, so accepting the drop would play the "accepted" animation over a queue
            // nothing joined. Returning false gives the user Finder's reject animation instead.
            guard !model.isRunning else { return false }
            loadDroppedURLs(providers)
            return true
        }
        .overlay { dropHighlight }
        // A popover left open when a run starts must not silently swallow "Use this" as a
        // no-op mid-run (R9): dismiss it the moment the run begins, matching the disable
        // convention used elsewhere for `model.isRunning`.
        .onChange(of: model.isRunning) { _, isRunning in
            if isRunning { heavyPopoverJobID = nil }
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
                } else if let summary = model.armedSummary {
                    SuccessBanner(headline: armedHeadline(summary),
                                  detail: armedDetail(summary),
                                  tone: .accent)
                        .transition(.opacity.combined(with: .move(edge: .top)))
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
                                onHeavyTap: {
                                    guard !model.isRunning else { return }
                                    heavyPopoverJobID = job.id
                                },
                                heavyCapsuleTitle: model.versions(for: job)?.capsuleTitle ?? "Heavy compression",
                                heavyPopoverPresented: isShowingHeavyPopover(for: job.id),
                                heavyPopoverContent: { AnyView(heavyPopover(for: job)) },
                                lead: lead(for: job),
                                onLeadTap: { Task { await model.useVersion(.previous, for: job) } },
                                metaAccent: metaAccent(for: job))
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel("Quality")
                    // Five of the six refuse-while-running sites — this selector, "+ Add", "Clear
                    // finished", `outputFolderRow` and the drop guard — key on `model.isRunning`,
                    // which now spans BOTH run phases: unchanged, deliberately (R9). The sixth,
                    // `useVersion(_:for:)`, refuses in the model instead of being disabled here.
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
        if let row = model.versions(for: job) {
            VersionsPopover(
                versions: row,
                // Request panel dismissal before the swap (SwiftUI dismisses asynchronously, so
                // a closing panel may still render one stale frame — accepted; the frozen items
                // collection is untouched, so the panel never sees a shrinking collection).
                onUse: { slot in
                    quickLookURL = nil
                    Task { await model.useVersion(slot, for: job) }
                    heavyPopoverJobID = nil
                },
                onPreview: { url in
                    freezeQuickLookItems(row.cards.map(\.version.url))
                    quickLookURL = url
                })
        }
    }

    /// Frozen at preview-open and never allowed to SHRINK: a SwiftUI collection feeding
    /// `.quickLookPreview` that loses items while the panel is alive trips the
    /// `QLPreviewPanelController` KVO reload — the field crash. Two versions used to be the only
    /// case, so a plain overwrite was always same-size; with two OR three, previewing a 3-version
    /// row and then a 2-version one would shrink it.
    ///
    /// The padding repeats the CURRENT row's own last URL, never the previous set's tail. Padding
    /// with the old tail would leave the panel's arrow keys walking the user into a file belonging
    /// to a different row — or, after a slot replacement or "Clear finished", into a discarded
    /// path that no longer exists. A duplicate of a URL already in the set is inert by comparison:
    /// the arrows land back on a page the user is already looking at.
    private func freezeQuickLookItems(_ items: [URL]) {
        // An empty `items` has no last URL to pad with — falling through would assign `[]` and
        // shrink the frozen set to nothing, the exact KVO-reload crash this function exists to
        // prevent. Unreachable today (no cards, no preview button), but the contract above is
        // unconditional, so the guard is too.
        guard !items.isEmpty else { return }
        var next = items
        if let last = next.last {
            while next.count < frozenQuickLookItems.count { next.append(last) }
        }
        frozenQuickLookItems = next
    }

    private func isShowingHeavyPopover(for id: ToolJob.ID) -> Binding<Bool> {
        Binding(
            get: { heavyPopoverJobID == id },
            set: { isPresented in if !isPresented { heavyPopoverJobID = nil } }
        )
    }

    /// Batch progress with a live count, mirroring the mockup's "Compressing 2 of 3…" bar. Scoped
    /// to the RUN, not the list (R9): rows finished by an earlier batch are not this run's work.
    private var runningBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            LinearProgress(fraction: model.runProgress)
            Text(batchProgressText(runVerb, finished: model.runFinishedCount,
                                   total: model.runTotalCount))
                .themeFont(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize()
            LinkButton(title: "Cancel") { model.cancel() }
        }
    }

    /// "Recompressing" only when the run is nothing but armed rows; a mixed run is a compress run
    /// with recompression in it, and one bar cannot say both.
    private var runVerb: String {
        model.runComposition.queued == 0 && model.runComposition.armed > 0
            ? "Recompressing" : "Compressing"
    }

    /// `.queued` only — unchanged, deliberately: an armed row is a FINISHED row and stays
    /// non-removable, per D5's deferral.
    private func canRemove(_ job: ToolJob) -> Bool {
        if case .queued = job.state { return !model.isRunning }
        return false
    }

    /// Unchanged, deliberately: `displayedSizes` was re-derived off the version store in Task 4,
    /// so this and `savedDetail`/`savedSummary` below already read the store (R17).
    private var savedBytes: Int {
        model.jobs.reduce(0) { sum, job in
            guard let (before, after) = model.displayedSizes(for: job) else { return sum }
            return sum + max(0, before - after)
        }
    }

    private var savedHeadline: String { "Saved \(byteString(savedBytes))" }

    /// Both fixed regions carry the story, because armed rows can be scrolled out of sight (R4).
    private func armedHeadline(_ summary: CompressViewModel.ArmedSummary) -> String {
        if summary.queuedCount > 0 {
            return "Will compress \(summary.queuedCount) and recompress \(summary.armedCount) PDFs"
        }
        let n = summary.armedCount
        return "Will recompress \(n) PDF\(n == 1 ? "" : "s") at \(model.preset.title)"
    }

    /// Summed over armed rows with a confident prediction only; nil when none has one, so the
    /// banner shows no detail line rather than a fabricated zero (R4).
    private func armedDetail(_ summary: CompressViewModel.ArmedSummary) -> String? {
        guard let extra = summary.extraSaving else { return nil }
        return extra > 0 ? "\u{2248} saves another \(byteString(extra))"
                         : "files may grow for the extra quality"
    }

    private var savedDetail: String {
        var before = 0, after = 0
        var n = 0
        for job in model.jobs {
            // Only files with a real size delta: `displayedSizes` is nil for "already
            // optimised", for OCR outcomes and for every failure, and counting those against
            // totals they contributed nothing to claimed a whole batch had shrunk when one
            // file did.
            if let (b, a) = model.displayedSizes(for: job) { before += b; after += a; n += 1 }
        }
        let pct = before > 0 ? Int(((Double(before - after) / Double(before)) * 100).rounded()) : 0
        return "\(n) PDF\(n == 1 ? "" : "s") · \(byteString(before)) → \(byteString(after)) · \(pct)% smaller"
    }

    private var summaryRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(queueSummary).themeFont(.captionBold).foregroundStyle(Theme.Colors.text)
            Spacer(minLength: Theme.Spacing.small)
            if !model.isRunning {
                LinkButton(title: "+ Add") { model.add(FilePicker.choosePDFs()) }
            }
            // Gated on the run, like "+ Add" beside it: clearing mid-batch drops the progress
            // bar's denominator under the running batch and silently omits the files already
            // compressed from the final summary.
            // Also gated on `isSwitchRerunning`: a mid-switch row still shows/queues as `.done`
            // (ec61602), so `clearFinished()` refuses outright while one is in flight — mirror
            // that here so the button doesn't invite a click that does nothing.
            if hasFinishedJobs, !model.isRunning, model.isSwitchRerunning.isEmpty {
                LinkButton(title: "Clear finished") { model.clearFinished() }
            }
        }
    }

    /// How the output will be named. With a single file in the queue that is its real resulting
    /// filename, which is more use than a placeholder; with several, the pattern they all follow.
    private var outputNamePreview: String {
        // A recompress replaces the row's existing file — naming a new one would be a lie. But a
        // no-gain row has shipped nothing (`shipped == nil`), so an armed set that is ALL no-gain
        // rows is about to create fresh `<name>-compressed.pdf` files, not replace anything — only
        // claim the replace text when every armed row actually has a file to replace.
        if model.pendingCount == 0, model.armedCount > 0,
           model.armedJobs.allSatisfy({ model.versions(for: $0)?.shipped != nil }) {
            return "replacing the current file"
        }
        if model.jobs.count == 1, let job = model.jobs.first {
            let base = job.url.deletingPathExtension().lastPathComponent
            return "as \(base)-compressed.pdf"
        }
        return "as <file>-compressed.pdf"
    }

    private func revealOutputs() {
        // Fall back to the originals' folder when nothing new was written (every file was
        // already optimised), so the button still does something sensible.
        let outputs = model.jobs.compactMap { model.versions(for: $0)?.shipped?.url ?? $0.resultURL }
        let urls = outputs.isEmpty ? model.jobs.map(\.url) : outputs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Open the shipped version if one exists, otherwise the original. The STORE is asked first: a
    /// recompressed no-gain row has a delivered file while the queue's `resultURL` is still nil.
    /// (OCR's own `resultURL ?? url` path is untouched — R19.)
    private func open(_ job: ToolJob) {
        NSWorkspace.shared.open(model.versions(for: job)?.shipped?.url ?? job.resultURL ?? job.url)
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
    /// queue replaces it, this ring is the only thing telling you the pane still accepts files —
    /// so it stays dark while a batch runs, when the drop is refused.
    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted, !model.jobs.isEmpty, !model.isRunning {
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
        case .done:
            // The version store, not the outcome shape, decides what a finished row shows: a
            // recompressed no-gain row keeps its `.done(.noGain)` outcome while genuinely shipping
            // a file, and a plain gs re-run of a heavy row still has two versions to offer (R15).
            guard let row = model.versions(for: job), let shipped = row.shipped else {
                return .unchanged("Already optimised")
            }
            return row.count > 1
                ? .doneHeavy(originalBytes: row.originalBytes, newBytes: shipped.bytes)
                : .done(originalBytes: row.originalBytes, newBytes: shipped.bytes)
        case .failed(let message):
            return .error(message)
        }
    }

    /// The leading item of a finished row's cluster.
    ///
    /// Precedence, in order: a missing-original error (arming is impossible, so it overrides
    /// everything else); any recompress/switch failure message — the outcome of a button the user
    /// pressed, so it outranks a plain finished row and survives until the user changes preset or
    /// the next run clears it; then the armed/futile/instant-switch lead. One exception: an
    /// instant-switch failure keeps the "Switch instantly" link as the lead instead of the error,
    /// because that link IS the retry control — showing the failure text here would tell the user
    /// to try again while hiding the only thing they can tap to do it. Its message goes out
    /// through `metaAccent` instead (see below).
    private func lead(for job: ToolJob) -> FileRow.Lead? {
        let state = model.recompressState(for: job)
        // R10, at arming time: an armed row whose ORIGINAL has gone cannot be recompressed at all,
        // so it must say so rather than show a confident pill promising a size nothing can produce.
        // Ahead of everything, because it invalidates the armed claim itself.
        if case .armed = state, model.isOriginalMissing(for: job) {
            return .error("The original file is no longer where it was")
        }
        // An error OUTRANKS the armed pill — unconditionally, not only when the row is disarmed.
        // A failed recompress records no preset (R1), so the row RE-ARMS the instant the attempt
        // fails; the old `state == .none` guard therefore suppressed R12's message on exactly the
        // rows that had just failed, and an explicit button press would have failed silently. The
        // message stays authoritative until the user changes preset or the next run starts — both
        // of which clear `recompressErrors` at source, so no guard is needed here. EXCEPT
        // `.instantSwitch`: see the doc comment above — that state keeps its link as the lead.
        if let message = model.recompressErrors[job.id] {
            if case .instantSwitch = state {} else { return .error(message) }
        }
        switch state {
        case .armed(let target):
            guard let predicted = model.recompressPrediction(for: job, at: target) else {
                return .accentPill("→ may not shrink")
            }
            // The "≈" marker stays throughout: the figure is approximate however it was derived
            // (R16), so this never borrows the queued row's "~" fallback marker.
            return .accentPill("→ \u{2248}\(byteString(predicted))")
        case .futile(let target):
            return .neutralPill("No saving at \(target.title)")
        case .instantSwitch:
            return .link("Switch instantly")
        case .none:
            return nil
        }
    }

    private func metaAccent(for job: ToolJob) -> String? {
        switch model.recompressState(for: job) {
        case .armed(let target):
            // A row that has shipped nothing is being TRIED at the new preset, not re-shipped.
            return model.versions(for: job)?.shipped == nil
                ? "will try \(target.title)"
                : "will recompress at \(target.title)"
        case .instantSwitch(let target):
            // A failed switch keeps the link as the lead (see `lead(for:)`), so its message rides
            // the meta clause instead of being swallowed by an `.error` lead.
            return model.recompressErrors[job.id] ?? "your \(target.title) version is kept"
        case .futile, .none:
            return nil
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
        let queued = model.pendingCount, armed = model.armedCount
        if queued > 0, armed > 0 { return "Compress \(queued) · Recompress \(armed)" }
        if armed > 0 { return "Recompress \(armed) PDF\(armed == 1 ? "" : "s")" }
        return queued > 0 ? "Compress \(queued) PDF\(queued == 1 ? "" : "s")" : "Compress"
    }

    private var footerNote: String {
        if model.isRunning {
            return batchProgressText(runVerb, finished: model.runFinishedCount,
                                     total: model.runTotalCount)
        }
        // An armed set hasn't run yet, so a finished-batch "Saved X · Y% smaller" footnote would
        // read as a completed-work claim beside the still-to-run "Recompress" button. The mockup
        // (recompress-ux-mockup.html, screen 2) swaps it for the originals reassurance instead.
        if model.armedCount > 0 {
            return "Recompresses from the originals — nothing is overwritten until it succeeds."
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

    /// Whole-list, NOT run-scoped, deliberately: its only consumer is "Clear finished", which
    /// clears every finished row regardless of which batch finished it (R9).
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
    CompressView(model: CompressViewModel())
        .frame(width: 720, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Compress – Dark") {
    CompressView(model: CompressViewModel())
        .frame(width: 720, height: 520)
        .preferredColorScheme(.dark)
}
