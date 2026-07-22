// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI
import UniformTypeIdentifiers

/// The OCR tool view: batch drop/pick, an options panel (accuracy + language) in place of
/// Compress's preset cards, and an "OCR N PDFs" action. Styled with the `Theme` token stub
/// only; the full design system lands in Track D and is applied in the S.1 polish pass.
struct OCRView: View {
    @StateObject private var model = OCRViewModel()
    @State private var isTargeted = false
    @State private var isImporting = false

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
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            optionsPanel
            dropZone
            if !model.jobs.isEmpty { jobList }
            Spacer(minLength: 0)
            actionBar
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("OCR")
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    // MARK: sections

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Accuracy").font(.subheadline).foregroundStyle(.secondary)
                Picker("Accuracy", selection: $model.options.accuracy) {
                    ForEach(Accuracy.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRunning)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Language").font(.subheadline).foregroundStyle(.secondary)
                Picker("Language", selection: languageSelection) {
                    ForEach(languages, id: \.name) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
                .disabled(model.isRunning)
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Bridges the single-select menu (`String?` code) to `options.languages` (an array).
    private var languageSelection: Binding<String?> {
        Binding(
            get: { model.options.languages.first },
            set: { model.options.languages = $0.map { [$0] } ?? [] }
        )
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Theme.Colors.accent : Color.secondary.opacity(0.5))
            .frame(height: 150)
            .overlay {
                VStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Drop PDFs to make searchable")
                        .font(.headline)
                    Button("Choose PDFs…") { isImporting = true }
                        .buttonStyle(.bordered)
                }
            }
            .onDrop(of: [.pdf], isTargeted: $isTargeted) { providers in
                loadDroppedURLs(providers)
                return true
            }
    }

    private var jobList: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.small) {
                ForEach(model.jobs) { job in
                    OCRJobRow(job: job)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private var actionBar: some View {
        HStack {
            if model.jobs.contains(where: { if case .done = $0.state { return true } else { return false } }) {
                Button("Clear finished") { model.clearFinished() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            if model.isRunning { ProgressView().controlSize(.small) }
            Button(action: model.run) {
                Text(actionTitle).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)
            .disabled(!model.canRun)
        }
    }

    private var actionTitle: String {
        let n = model.pageCandidateCount
        return n > 0 ? "OCR \(n) PDF\(n == 1 ? "" : "s")" : "OCR"
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

/// One file's row: name plus a state-dependent trailing detail (mirrors Compress's row).
private struct OCRJobRow: View {
    let job: ToolJob

    var body: some View {
        HStack {
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
            Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            detail
        }
        .padding(Theme.Spacing.small)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    @ViewBuilder
    private var detail: some View {
        switch job.state {
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .analysing:
            Text("Analysing…").foregroundStyle(.secondary)
        case .running(let fraction):
            if fraction > 0 {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done(let outcome):
            outcomeLabel(outcome)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).lineLimit(1)
        }
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: JobOutcome) -> some View {
        switch outcome {
        case .ocrAdded(let pages, let skipped):
            let suffix = skipped > 0 ? "  (\(skipped) already had text)" : ""
            Label("Searchable — \(pages) page\(pages == 1 ? "" : "s")\(suffix)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).lineLimit(1)
        case .alreadySearchable:
            Label("Already searchable", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .compressed, .noGain:
            Text("Done").foregroundStyle(.green)
        }
    }
}
