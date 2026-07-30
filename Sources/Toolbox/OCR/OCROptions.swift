// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// User-tunable OCR settings (spec §6). `languages` empty means auto-detect.
struct OCROptions: Equatable {
    var accuracy: Accuracy = .accurate
    var languages: [String] = []

    /// The languages the OCR popover offers: English plus the eight the design names, each paired
    /// with its Vision recognition-language code. The codes were read from
    /// `VNRecognizeTextRequest.supportedRecognitionLanguages()`, not assumed.
    ///
    /// Vision supports far more than these; the list is deliberately short because a dropdown of
    /// thirty is a worse answer than auto-detect (the default when nothing is chosen). Note that
    /// `.fast` recognition supports only the six Latin-script entries — Chinese, Japanese and
    /// Korean need `.accurate`.
    static let curatedLanguages: [(code: String, display: String)] = [
        ("en-US", "English"),
        ("de-DE", "German"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"),
        ("zh-Hans", "Chinese"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
    ]
}

/// Vision's recognition level: `.fast` trades accuracy for speed; `.accurate` is the default.
enum Accuracy: String, CaseIterable, Identifiable {
    case fast
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .accurate: return "Accurate"
        }
    }
}
