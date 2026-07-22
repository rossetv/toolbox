// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Names outputs `<name>-<suffix>.pdf` next to the original (or in `folder` if given),
/// never overwriting: on a collision it appends `-1`, `-2`, … (spec §5.4).
enum FileNaming {
    static func output(for input: URL, suffix: String, folder: URL?) -> URL {
        let directory = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension

        var candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
