// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI
import UniformTypeIdentifiers

/// The Compress tool view — batch drop/pick, preset picker, optional output-folder picker,
/// per-file rows (estimate → live progress → real before/after), cancel. Styled with the
/// `Theme` token stub only; the full design system lands in Track D and is applied in the
/// S.1 polish pass.
struct CompressView: View {
    @StateObject private var model = CompressViewModel()
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var isChoosingOutputFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            presetPicker
            outputFolderRow
            dropZone
            if !model.jobs.isEmpty { jobList }
            Spacer(minLength: 0)
            actionBar
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Compress")
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .fileImporter(isPresented: $isChoosingOutputFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.outputFolder = url }
        }
        .overlay(alignment: .top) { loadErrorBanner }
    }

    // MARK: sections

    private var presetPicker: some View {
        Picker("Quality", selection: $model.preset) {
            ForEach(CompressPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isRunning)
    }

    private var outputFolderRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if let folder = model.outputFolder {
                Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Button("Change…") { isChoosingOutputFolder = true }.buttonStyle(.borderless)
                Button("Use original location") { model.outputFolder = nil }.buttonStyle(.borderless)
            } else {
                Text("Save next to each original").foregroundStyle(.secondary)
                Button("Choose folder…") { isChoosingOutputFolder = true }.buttonStyle(.borderless)
            }
            Spacer()
        }
        .disabled(model.isRunning)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Theme.Colors.accent : Color.secondary.opacity(0.5))
            .frame(height: 150)
            .overlay {
                VStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Drop PDFs here")
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
                    JobRow(job: job)
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
            if model.isRunning {
                Button("Cancel") { model.cancel() }.buttonStyle(.bordered)
                ProgressView().controlSize(.small)
            }
            Button(action: model.compress) {
                Text("Compress").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)
            .disabled(!model.canCompress)
        }
    }

    @ViewBuilder
    private var loadErrorBanner: some View {
        if let error = model.loadError {
            Text(error)
                .font(.callout)
                .padding(Theme.Spacing.small)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .padding(Theme.Spacing.small)
        }
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

/// One file's row: name plus a state-dependent trailing detail.
private struct JobRow: View {
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
            estimateLabel
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
    private var estimateLabel: some View {
        if let estimate = job.estimate {
            // "~" marks a typical-range fallback (content type unknown/analysis timed out);
            // "≈" marks a real sample-based prediction for this file.
            let marker = estimate.isFallback ? "~" : "≈"
            Text("\(marker)\(byteString(estimate.predictedBytes)) predicted")
                .foregroundStyle(.secondary)
        } else {
            Text("Queued").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: JobOutcome) -> some View {
        switch outcome {
        case .compressed(let before, let after):
            let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            Label("\(byteString(before)) → \(byteString(after))  (−\(saved)%)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .noGain:
            Label("Already optimised", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .ocrAdded, .alreadySearchable:
            Text("Done").foregroundStyle(.green)
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
