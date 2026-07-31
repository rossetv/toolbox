// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import SwiftUI

/// The batch OCR popover (handoff screen 04b): language + accuracy, both batch-wide
/// (`QueueViewModel.ocrOptions`). Fast is refused whenever a CJK language is selected — the VM
/// clamps the stored value too (`QueueViewModel.clampingAccuracy`), but the control itself must
/// not dangle a choice the model will silently override underneath the user.
struct OCRPopover: View {
    @ObservedObject var model: QueueViewModel

    var body: some View {
        PopoverChrome(width: 350) {
            VStack(alignment: .leading, spacing: 14) {
                DropdownRow(label: "Language on the page",
                           options: Self.languageDisplayNames,
                           selection: languageSelection)
                Text(alsoAvailableLine)
                    .themeFont(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("How carefully to read")
                    SegmentedRow(options: Accuracy.allCases.map(\.title), selection: accuracyIndex)
                        .disabled(fastDisabled)
                    Text(accuracyCaption)
                        .themeFont(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text("Pages that already contain text are left alone.")
                    .themeFont(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(8)
        }
    }

    private var fastDisabled: Bool { Self.fastDisabled(languages: model.ocrOptions.languages) }

    /// Whether picking Fast right now would be a dead choice — the same clamp
    /// `QueueViewModel.clampingAccuracy` applies to the stored value, read here so the control
    /// never offers a combination the model is about to override (one source of truth, no new
    /// vocabulary for the same rule).
    static func fastDisabled(languages: [String]) -> Bool {
        QueueViewModel.clampingAccuracy(OCROptions(accuracy: .fast, languages: languages)).accuracy != .fast
    }

    private var accuracyCaption: String {
        fastDisabled
            ? "Chinese, Japanese and Korean need Accurate — Fast cannot read them."
            : "Accurate takes about three times as long and is worth it for handwriting, faint fax paper and small print."
    }

    private var currentLanguageDisplay: String {
        let code = model.ocrOptions.languages.first ?? OCROptions.curatedLanguages[0].code
        return OCROptions.curatedLanguages.first { $0.code == code }?.display
            ?? OCROptions.curatedLanguages[0].display
    }

    /// The design's static "Also available: …" hint, kept honest against whichever language is
    /// actually selected by excluding it from the list rather than hard-coding English's seven
    /// alternatives.
    private var alsoAvailableLine: String {
        let others = OCROptions.curatedLanguages
            .map(\.display)
            .filter { $0 != currentLanguageDisplay }
        return "Also available: \(others.joined(separator: ", "))."
    }

    static var languageDisplayNames: [String] { OCROptions.curatedLanguages.map(\.display) }

    private var languageSelection: Binding<String> {
        Binding(
            get: { currentLanguageDisplay },
            set: { display in
                guard let code = OCROptions.curatedLanguages.first(where: { $0.display == display })?.code else { return }
                model.ocrOptions.languages = [code]
            }
        )
    }

    private var accuracyIndex: Binding<Int> {
        Binding(
            get: { model.ocrOptions.accuracy == .fast ? 0 : 1 },
            set: { model.ocrOptions.accuracy = $0 == 0 ? .fast : .accurate }
        )
    }
}

#Preview("OCRPopover") {
    let model = QueueViewModel(engine: nil)
    return OCRPopover(model: model)
        .padding(60)
        .background(Theme.Colors.background)
}
