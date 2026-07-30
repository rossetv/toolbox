// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// A job reached the concurrent run with no name in the queue's reservation ledger — every row
/// reserves its delivery name when it is ADDED (spec §6.5), so this is a row whose entry was
/// released or never made. Falling back to a second, on-disk-only
/// `FileNaming.output(for:suffix:folder:)` call from inside the concurrent job body would
/// re-introduce the very TOCTOU race the reservation exists to close, so a missing reservation
/// fails that one job loudly instead.
struct MissingOutputReservationError: LocalizedError {
    var errorDescription: String? {
        "No output name was reserved for this file before the batch started."
    }
}

/// Names outputs `<name>-<suffix>.pdf` next to the original (or in `folder` if given),
/// never overwriting: on a collision it appends `-1`, `-2`, … (spec §5.4).
enum FileNaming {
    /// Single-file output name — no cross-file coordination needed.
    static func output(for input: URL, suffix: String, folder: URL?) -> URL {
        var reserved = Set<String>()
        return output(for: input, suffix: suffix, folder: folder, reserving: &reserved)
    }

    /// Batch-safe output name. Names are picked serially on one thread, threading `reserved`
    /// through each call: this avoids a collision that a purely on-disk check cannot see — two
    /// inputs with the same basename from different folders, sent to the same output folder,
    /// would otherwise both resolve to `<name>-<suffix>.pdf` and the second job's atomic rename
    /// would fail. Names already handed out are skipped alongside names already on disk.
    /// Allocation must never run from inside a concurrent job body.
    ///
    /// `reserved` is keyed on `reservationKey(for:)` rather than the raw `URL`, because APFS is
    /// case-insensitive (and normalisation-insensitive) by default: `Report.pdf` and `report.pdf`
    /// are the SAME file on disk even though they are different `URL` values, so a byte-exact
    /// `Set<URL>` would let both batch entries "reserve" distinct names that later collide at
    /// `moveItem`.
    static func output(for input: URL, suffix: String, folder: URL?, reserving reserved: inout Set<String>) -> URL {
        let directory = folder ?? input.deletingLastPathComponent()
        // Clamp the extension itself first: `ext` is attacker-controlled (`input.pathExtension`,
        // and APFS permits any extension length as long as the whole name is ≤ 255 bytes), so an
        // absurdly long extension must not be allowed to eat the entire budget before `base` gets
        // a look-in — see `truncatedBase`'s doc comment.
        let rawExt = input.pathExtension.isEmpty ? "pdf" : input.pathExtension
        let ext = truncatedToByteBudget(rawExt, maxBytes: maxExtensionBytes)
        let base = truncatedBase(input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: ext)

        var candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(reservationKey(for: candidate)) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)-\(counter).\(ext)")
            counter += 1
        }
        reserved.insert(reservationKey(for: candidate))
        return candidate
    }

    /// macOS APFS/HFS+ filenames are limited to 255 UTF-8 bytes. A long basename (a ~250-character
    /// name, or ~90 CJK characters at 3 bytes each) would otherwise exit the dedupe loop above only
    /// to fail `FileManager.moveItem` with `ENAMETOOLONG` — every time, since retrying never
    /// shortens it. Truncate `base` up front, preserving the suffix/extension and leaving headroom
    /// for the dedupe counter, so the name that comes out the other end is always writable.
    ///
    /// `ext` must already be clamped by the caller (`maxExtensionBytes`) — an unclamped, absurdly
    /// long extension could exhaust the whole 255-byte budget on its own, leaving no room for
    /// `base` at all (`budget <= 0`); with `ext` bounded that can no longer happen, but the guard
    /// below still degrades to an empty base rather than returning `base` untruncated.
    private static func truncatedBase(_ base: String, suffix: String, ext: String) -> String {
        let maxFilenameBytes = 255
        let reservedForCounter = "-\(suffix)-9999.\(ext)".utf8.count
        let budget = maxFilenameBytes - reservedForCounter
        guard budget > 0 else { return "" }
        guard base.utf8.count > budget else { return base }
        return truncatedToByteBudget(base, maxBytes: budget)
    }

    /// The longest extension we'll honour verbatim. Real extensions are a handful of characters
    /// ("pdf", "tar.gz" fragments); this exists solely to stop a hostile/absurd `pathExtension`
    /// from eating the byte budget `truncatedBase` needs for the basename (see m2 in review).
    private static let maxExtensionBytes = 20

    /// Truncates `string` to at most `maxBytes` UTF-8 bytes, always on a whole grapheme cluster
    /// boundary (never splits a multi-byte character).
    private static func truncatedToByteBudget(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var truncated = string
        while truncated.utf8.count > maxBytes {
            truncated.removeLast()
        }
        return truncated
    }

    /// Case- and normalisation-insensitive key matching APFS/HFS+'s own filename comparison.
    /// Canonicalised first (§5.1: identity is compared on canonical paths) so a symlinked
    /// directory (e.g. `~/Docs` → `~/Documents`) can't let two inputs "reserve" what is really
    /// the same on-disk name under two different-looking keys.
    ///
    /// Internal rather than private so a caller holding a path it did not allocate — an existing
    /// result being recompressed — can seed it into the same reservation set (R11).
    static func reservationKey(for url: URL) -> String {
        url.canonical.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
