// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Names outputs `<name>-<suffix>.pdf` next to the original (or in `folder` if given),
/// never overwriting: on a collision it appends `-1`, `-2`, … (spec §5.4).
enum FileNaming {
    /// Single-file output name — no cross-file coordination needed.
    static func output(for input: URL, suffix: String, folder: URL?) -> URL {
        var reserved = Set<String>()
        return output(for: input, suffix: suffix, folder: folder, reserving: &reserved)
    }

    /// Batch-safe output name. A single run picks all its output names up front on one thread,
    /// threading `reserved` through each call: this avoids a collision that a purely on-disk
    /// check cannot see — two inputs with the same basename from different folders, sent to the
    /// same output folder, would otherwise both resolve to `<name>-<suffix>.pdf` and the second
    /// job's atomic rename would fail. Names already handed out this run are skipped alongside
    /// names already on disk. Allocation must run BEFORE the concurrent compression starts.
    ///
    /// `reserved` is keyed on `reservationKey(for:)` rather than the raw `URL`, because APFS is
    /// case-insensitive (and normalisation-insensitive) by default: `Report.pdf` and `report.pdf`
    /// are the SAME file on disk even though they are different `URL` values, so a byte-exact
    /// `Set<URL>` would let both batch entries "reserve" distinct names that later collide at
    /// `moveItem`.
    static func output(for input: URL, suffix: String, folder: URL?, reserving reserved: inout Set<String>) -> URL {
        let directory = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension

        var candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(reservationKey(for: candidate)) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)-\(counter).\(ext)")
            counter += 1
        }
        reserved.insert(reservationKey(for: candidate))
        return candidate
    }

    /// Case- and normalisation-insensitive key matching APFS/HFS+'s own filename comparison.
    private static func reservationKey(for url: URL) -> String {
        url.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
