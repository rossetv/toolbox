// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CCITT Group 4 encoding of a bilevel page, for embedding as a PDF image XObject.
///
/// The encoder is ImageIO's: the image is written to an in-memory TIFF with
/// `Compression = 4` (CCITT G4) and the compressed strip is lifted back out. PDF's
/// `/CCITTFaxDecode` with `/K -1` consumes exactly that bitstream, so no bespoke encoder — and no
/// native image library — is needed. TIFF is used purely as a transport for the codec.
enum CCITTEncoder {

    struct Encoded {
        let data: Data          // the raw G4 bitstream, ready for /CCITTFaxDecode
        let width: Int
        let height: Int
        /// True when a 1 bit means black. TIFF photometric 0 (WhiteIsZero) is the usual output
        /// for G4, which corresponds to PDF's default `/BlackIs1 false`.
        let blackIs1: Bool
    }

    /// Encode a bilevel bitmap as CCITT G4. Returns `nil` — never throws — for a degenerate
    /// image, an unavailable ImageIO destination, or a TIFF strip that couldn't be recovered
    /// intact, so callers can simply fall back; no caller has ever needed to distinguish why.
    static func encode(_ image: CGImage) -> Encoded? {
        guard image.width > 0, image.height > 0 else { return nil }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.tiff.identifier as CFString, 1, nil
        ) else { return nil }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 4] as [CFString: Any],
            kCGImagePropertyDepth: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let tiff = buffer as Data
        guard let strip = Self.strip(fromTIFF: tiff) else { return nil }
        return Encoded(data: strip.data,
                       width: image.width,
                       height: image.height,
                       blackIs1: strip.photometric == 1)
    }

    // MARK: TIFF strip extraction

    struct Strip {
        let data: Data
        let photometric: Int
    }

    /// Pull the single compressed strip out of a baseline TIFF.
    ///
    /// Internal rather than private so the parser hardening below — bounds-checked offsets, a
    /// declared-count bound, and the single-strip requirement — is directly unit-testable: the
    /// TIFF `encode(_:)` feeds it is always ImageIO's own well-formed output, so none of those
    /// guards can currently be exercised end-to-end through `encode(_:)` itself.
    ///
    /// Deliberately a minimal reader: this parses only the TIFF *we* just produced, so it needs
    /// nothing beyond the first IFD and a handful of tags. Every offset and declared count is
    /// bounds-checked anyway — the parser must not be the weak point even on input it is
    /// supposed to trust.
    static func strip(fromTIFF tiff: Data) -> Strip? {
        guard tiff.count >= 8 else { return nil }
        let little: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= tiff.count else { return nil }
            let a = Int(tiff[offset]), b = Int(tiff[offset + 1])
            return little ? a | (b << 8) : (a << 8) | b
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= tiff.count else { return nil }
            let bytes = (0..<4).map { Int(tiff[offset + $0]) }
            return little
                ? bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
                : bytes[3] | bytes[2] << 8 | bytes[1] << 16 | bytes[0] << 24
        }

        guard let ifd = u32(4), let entryCount = u16(ifd) else { return nil }

        var offsets: [Int] = []
        var counts: [Int] = []
        var photometric = 0

        for index in 0..<entryCount {
            let entry = ifd + 2 + index * 12
            guard let tag = u16(entry), let type = u16(entry + 2), let count = u32(entry + 4) else {
                return nil
            }
            // A value of 4 bytes or fewer is stored inline in the entry, otherwise the entry
            // holds a pointer to it.
            let width = (type == 3) ? 2 : 4
            func values() -> [Int] {
                // Bound the declared value count against what the buffer could possibly hold
                // before ever iterating it: an unbounded `count` (up to UInt32.max) would
                // otherwise turn this into a multi-million-iteration loop over a TIFF a few KB
                // in size. Scoped to `values()` — called only for the three tags read below —
                // rather than every entry: `width` above is only correct for SHORT/LONG (types
                // 3/4), so bounding every entry by it would wrongly reject a legitimate
                // large-count BYTE/UNDEFINED metadata tag this parser never reads (an embedded
                // ICC profile, say — exactly what a real ImageIO TIFF carries).
                guard count >= 0, count <= tiff.count / max(width, 1) else { return [] }
                let inline = count * width <= 4
                let base = inline ? entry + 8 : (u32(entry + 8) ?? -1)
                guard base >= 0 else { return [] }
                return (0..<count).compactMap { i in
                    width == 2 ? u16(base + i * 2) : u32(base + i * 4)
                }
            }
            switch tag {
            case 262: photometric = values().first ?? 0
            case 273: offsets = values()
            case 279: counts = values()
            default: break
            }
        }

        // Exactly one strip: G4 strips are independently coded from a fresh all-white reference
        // line and byte-aligned, so a multi-strip TIFF concatenated naively would decode as
        // garbage past the first boundary — the composer emits a single `/Rows <full height>`
        // that assumes one continuous bitstream. ImageIO emits a single strip at every size
        // tested, so this never fires today; it is the fallback the moment that changes.
        guard offsets.count == 1, offsets.count == counts.count else { return nil }
        var payload = Data()
        for (offset, count) in zip(offsets, counts) {
            guard offset >= 0, count >= 0, offset + count <= tiff.count else { return nil }
            payload.append(tiff.subdata(in: offset..<(offset + count)))
        }
        guard !payload.isEmpty else { return nil }
        return Strip(data: payload, photometric: photometric)
    }
}
