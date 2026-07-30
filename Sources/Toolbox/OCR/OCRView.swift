// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The OCR tool view: batch drop/pick, an options panel (accuracy + language) in place of
/// Compress's quality presets, and an "OCR N PDFs" action. Shares Compress's design-system
/// furniture — `ToolHeader`, `DropZone`, `FileRow`, `SegmentedPreset`, `PrimaryButton` — so the
/// two tools read as one app.
struct OCRView: View {
    /// Owned by `RootView` — see `CompressView.model` for why a view-owned `@StateObject`
    /// loses the batch on every tool switch.
    @ObservedObject var model: OCRViewModel
    @State private var isTargeted = false

    /// Language override choices. `nil` = auto-detect. Curated common set (v1); Vision's full
    /// supported list is revision-dependent, so a fixed menu keeps the UI honest and simple.
    private let languages: [(name: String, code: String?)] = [
        ("Automatic", nil),
        ("English", "en-US"),
        ("French", "fr-FR"),
        ("German", "de-DE"),
        ("Spanish", "es-ES"),
        ("Italian", "it-IT"),
        ("Portuguese", "pt-BR"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                systemImage: Tool.ocr.systemImage,
                title: "OCR",
                subtitle: "Make scanned PDFs searchable. A hidden text layer is added — the page image is untouched.",
                tint: Tool.ocr.tint
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footerBar
        }
        .background(Theme.Colors.surface)
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
    }

    // MARK: sections

    @ViewBuilder
    private var content: some View {
        if model.jobs.isEmpty {
            DropZone(
                isTargeted: isTargeted,
                title: "Drop PDFs to make searchable",
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
                summaryRow
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(model.jobs) { job in
                        FileRow(name: job.url.lastPathComponent,
                                meta: meta(for: job),
                                fileURL: job.url,
                                status: status(for: job),
                                onRemove: canRemove(job) ? { model.remove(job) } : nil,
                                onOpen: { NSWorkspace.shared.open(job.resultURL ?? job.url) })
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel("Accuracy")
                    SegmentedPreset(options: accuracyOptions,
                                    selection: accuracySelection,
                                    isEnabled: !model.isRunning)
                }
                languageRow
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Only a still-queued file can leave the batch, and only between runs (matches Compress).
    private func canRemove(_ job: ToolJob) -> Bool {
        if case .queued = job.state { return !model.isRunning }
        return false
    }

    private var summaryRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(queueSummary).themeFont(.captionBold).foregroundStyle(Theme.Colors.text)
            Spacer(minLength: Theme.Spacing.small)
            if !model.isRunning {
                LinkButton(title: "+ Add") { model.add(FilePicker.choosePDFs()) }
            }
            // Gated on the run, like "+ Add" beside it: clearing mid-batch drops the progress
            // line's denominator under the running batch.
            if hasFinishedJobs, !model.isRunning {
                LinkButton(title: "Clear finished") { model.clearFinished() }
            }
        }
    }

    private var languageRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Language").themeFont(.caption).foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: Theme.Spacing.small)
            Picker("Language", selection: languageSelection) {
                ForEach(languages, id: \.name) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
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
            PrimaryButton(title: actionTitle, isEnabled: model.canRun) { model.run() }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.surface)
    }

    /// Dark while a batch runs: the drop is refused then, so an accent ring would promise a
    /// queue join that cannot happen.
    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted, !model.jobs.isEmpty, !model.isRunning {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.accent, lineWidth: 2)
                .padding(2)
                .allowsHitTesting(false)
        }
    }

    // MARK: job → row state

    /// Maps the queue's `JobState`/`RowOutcome` onto the presentational `FileRow.Status`.
    /// Outcomes this tool's engine never produces fall back to a plain "Done" rather than claiming
    /// something untrue about the file.
    private func status(for job: ToolJob) -> FileRow.Status {
        switch job.state {
        case .queued:
            return .queued(detail: "Queued", savedPercent: nil)
        case .analysing:
            return .analysing
        case .running(let fraction):
            return .inProgress(fraction: fraction > 0 ? fraction : nil)
        case .done(let outcome):
            switch outcome.ocr {
            // Too faint means the run recognised nothing and wrote no file — a green
            // "Searchable — 0 pages" would claim a success that never happened (§7.1). The
            // already-had-text tally is not a fact this outcome carries, so it is not repeated.
            case .tooFaint:
                return .unchanged("No text recognised")
            case .added(let pages, let skipped):
                let suffix = skipped > 0 ? " · \(skipped) already had text" : ""
                return .succeeded("Searchable — \(pages) page\(pages == 1 ? "" : "s")\(suffix)")
            case .alreadySearchable:
                return .unchanged("Already searchable")
            case .cancelled, .failed, nil:
                return .succeeded("Done")
            }
        case .failed(let message):
            return .error(message)
        }
    }

    private func meta(for job: ToolJob) -> String {
        inputSize(of: job).map(byteString) ?? job.url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: derived copy

    private var accuracyOptions: [SegmentedPresetOption] {
        // Exhaustive switch, so a new recognition level can't ship without its blurb.
        Accuracy.allCases.map { accuracy in
            switch accuracy {
            case .fast:
                return SegmentedPresetOption(id: accuracy.id, title: accuracy.title,
                                             subtitle: "A quicker pass over each page.",
                                             hint: "Best on clean, printed text")
            case .accurate:
                return SegmentedPresetOption(id: accuracy.id, title: accuracy.title,
                                             subtitle: "Vision's best recognition.",
                                             hint: "Recommended")
            }
        }
    }

    private var accuracySelection: Binding<String> {
        Binding(
            get: { model.options.accuracy.id },
            set: { if let accuracy = Accuracy(rawValue: $0) { model.options.accuracy = accuracy } }
        )
    }

    /// Bridges the single-select menu (`String?` code) to `options.languages` (an array).
    private var languageSelection: Binding<String?> {
        Binding(
            get: { model.options.languages.first },
            set: { model.options.languages = $0.map { [$0] } ?? [] }
        )
    }

    private var queueSummary: String {
        let count = model.jobs.count
        let files = "\(count) file\(count == 1 ? "" : "s")"
        let total = model.jobs.compactMap(inputSize).reduce(0, +)
        return total > 0 ? "\(files) · \(byteString(total))" : files
    }

    private var actionTitle: String {
        let n = model.pageCandidateCount
        return n > 0 ? "OCR \(n) PDF\(n == 1 ? "" : "s")" : "OCR"
    }

    private var footerNote: String {
        if model.isRunning {
            return batchProgressText("Reading", finished: finishedCount, total: model.jobs.count)
        }
        // Zero-page runs wrote no file, so they must not count towards "now searchable".
        let searchable = model.jobs.filter { job in
            if case .done(let outcome) = job.state, case .added(let pages, _) = outcome.ocr {
                return pages > 0
            } else {
                return false
            }
        }.count
        if searchable > 0 {
            return "\(searchable) PDF\(searchable == 1 ? " is" : "s are") now searchable."
        }
        return "Originals are never modified — a searchable copy is saved alongside."
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

    /// The input's size on disk — a local `URLResourceValues` read (see `CompressView`).
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

#Preview("OCR – Light") {
    OCRView(model: OCRViewModel())
        .frame(width: 720, height: 520)
        .preferredColorScheme(.light)
}

#Preview("OCR – Dark") {
    OCRView(model: OCRViewModel())
        .frame(width: 720, height: 520)
        .preferredColorScheme(.dark)
}
