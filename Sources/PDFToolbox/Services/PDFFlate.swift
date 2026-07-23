// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Compression
import Foundation

/// `FlateDecode`, the one stream filter the writer has to read.
enum PDFFlate {

    /// Inflate a `FlateDecode` stream body, refusing to produce more than `limit` bytes.
    ///
    /// The limit is not a nicety. A stream's compressed size says nothing about its expanded
    /// size — a few kilobytes of deflate expands to gigabytes of zeroes — and the body comes
    /// from an untrusted file, so an unbounded inflate is a decompression bomb with a direct
    /// path from "user OCRs a document" to "machine out of memory".
    ///
    /// PDF's `FlateDecode` is zlib (RFC 1950): a two-byte header, raw DEFLATE, an Adler-32
    /// trailer. Apple's `COMPRESSION_ZLIB` is the *raw* DEFLATE of RFC 1951, so the header is
    /// validated and stripped first. Files with the header absent — out of specification, but
    /// they exist — still decode, because the data is then already raw DEFLATE.
    static func inflate<C: RandomAccessCollection>(_ input: C, limit: Int) -> [UInt8]?
    where C.Element == UInt8, C.Index == Int {
        guard !input.isEmpty, limit > 0 else { return nil }
        var body = Array(input)

        if body.count >= 2 {
            let cmf = body[0], flg = body[1]
            let isZlibHeader = (cmf & 0x0F) == 8 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
            if isZlibHeader { body.removeFirst(2) }
        }
        guard !body.isEmpty else { return nil }

        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(dst_ptr: destination, dst_size: 0,
                                        src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        var output: [UInt8] = []
        var failed = false
        body.withUnsafeBufferPointer { source in
            stream.src_ptr = source.baseAddress!
            stream.src_size = source.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream,
                                                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    if output.count + produced > limit { failed = true; return }
                    output.append(contentsOf: UnsafeBufferPointer(start: destination, count: produced))
                }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { failed = true; return }
                // No progress and nothing left to read: truncated input.
                if produced == 0 && stream.src_size == 0 { failed = true; return }
            }
        }
        return failed || output.isEmpty ? nil : output
    }
}
