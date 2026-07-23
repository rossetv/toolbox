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

/// Encodes an `MRCSegmented` split into the three compressed layers a PDF page embeds, and the
/// inverse — `recompose` — that reconstitutes a full-page image from them for the verifier (R4)
/// to score against the original render.
enum MRCPageEncoder {

    struct EncodedPage {
        let background: MRCComposer.JPEGImage
        let foreground: MRCComposer.JPEGImage
        let mask: CCITTEncoder.Encoded
    }

    /// Layer JPEG qualities (ImageIO 0…1). Starting points from the reference pipeline's
    /// calibration; M2 retunes these against the reference outputs. The background carries the
    /// bulk of the byte budget — it is full-resolution-equivalent paper/photo content — while the
    /// foreground only has to survive ink hue, since the mask carries the actual glyph edges.
    static func layerQualities(for preset: CompressPreset) -> (bg: Double, fg: Double) {
        switch preset {
        case .smallestSize: return (0.30, 0.25)
        case .balanced: return (0.40, 0.30)
        case .maximumQuality: return (0.55, 0.40)
        }
    }

    /// CCITT mask + two JPEG layers. Fails closed (nil) the moment any of the three sub-encodes
    /// does — a partial `EncodedPage` has no meaningful use (D10: decline the whole page).
    static func encode(_ segmented: MRCSegmented, preset: CompressPreset) -> EncodedPage? {
        guard let maskImage = segmented.mask.cgImage,
              let mask = CCITTEncoder.encode(maskImage)
        else { return nil }
        let qualities = layerQualities(for: preset)
        guard let background = encodeJPEG(segmented.background, quality: qualities.bg),
              let foreground = encodeJPEG(segmented.foreground, quality: qualities.fg)
        else { return nil }
        return EncodedPage(background: background, foreground: foreground, mask: mask)
    }

    /// Shared JPEG encode — also the R5 fallback-page encoder (same machinery, spec R5), so kept
    /// generic over any `CGImage` rather than assuming an MRC layer.
    static func encodeJPEG(_ image: CGImage, quality: Double) -> MRCComposer.JPEGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return MRCComposer.JPEGImage(data: buffer as Data, width: image.width, height: image.height)
    }

    /// Decode + upscale the three layers back into one page image at the mask's pixel size — the
    /// verifier's candidate (D6). Mask-on (ink) pixels take the foreground colour, mask-off
    /// (paper) pixels take the background — the same selection a PDF viewer performs by painting
    /// `background` full-bleed then `foreground` gated by the mask soft-mask, so this must
    /// reproduce that composite, not just approximate it.
    static func recompose(_ page: EncodedPage) -> CGImage? {
        let width = page.mask.width, height = page.mask.height
        guard width > 0, height > 0,
              let backgroundImage = decodeJPEG(page.background.data),
              let foregroundImage = decodeJPEG(page.foreground.data),
              let maskImage = decodeMask(page.mask)
        else { return nil }

        // Upscale the two colour layers to the mask's pixel size with the context's default
        // interpolation (smooth — they are deliberately coarser than the mask); the mask itself
        // is already at that size, so its own draw uses no interpolation to keep its bits exact.
        guard let background = rgbBuffer(of: backgroundImage, width: width, height: height,
                                         interpolation: nil),
              let foreground = rgbBuffer(of: foregroundImage, width: width, height: height,
                                         interpolation: nil),
              let ink = greyBuffer(of: maskImage, width: width, height: height,
                                   interpolation: .none)
        else { return nil }

        // 8-bit DeviceRGB output, no alpha — row-addressed via the real width only (C1).
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            // BilevelBitmap/CCITT convention: 0 = black = ink.
            let source = ink[i] < 128 ? foreground : background
            bytes[i * 3] = source[i * 3]
            bytes[i * 3 + 1] = source[i * 3 + 1]
            bytes[i * 3 + 2] = source[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: decode helpers

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Decode a CCITT G4 mask back to a `CGImage` by re-wrapping the bare bitstream `encode(_:)`
    /// extracted it from into a minimal baseline TIFF — the mirror image of
    /// `CCITTEncoder.strip(fromTIFF:)` — and letting ImageIO's own TIFF/G4 decoder do the work.
    /// No bespoke G4 decoder exists in this codebase and none should: ImageIO already has one.
    private static func decodeMask(_ encoded: CCITTEncoder.Encoded) -> CGImage? {
        guard encoded.width > 0, encoded.height > 0, !encoded.data.isEmpty else { return nil }
        let tiff = tiffWrapping(encoded)
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A minimal little-endian baseline TIFF: header, one IFD with the handful of tags a G4
    /// strip needs (width, length, bits/sample, compression, photometric, one strip, rows/strip,
    /// strip byte count), then the bitstream itself as the sole strip. Every entry's value fits
    /// in the inline 4-byte field, so there is no out-of-line value section to place.
    private static func tiffWrapping(_ encoded: CCITTEncoder.Encoded) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }

        let ifdOffset = 8
        // tag, type, count, value — ascending by tag, as TIFF requires.
        let fixed: [(tag: Int, type: Int, count: Int, value: Int)] = [
            (256, 4, 1, encoded.width),                          // ImageWidth
            (257, 4, 1, encoded.height),                         // ImageLength
            (258, 3, 1, 1),                                      // BitsPerSample
            (259, 3, 1, 4),                                       // Compression = CCITT G4
            (262, 3, 1, encoded.blackIs1 ? 1 : 0),                 // PhotometricInterpretation
            (277, 3, 1, 1),                                      // SamplesPerPixel
            (278, 4, 1, encoded.height),                         // RowsPerStrip
            (279, 4, 1, encoded.data.count),                      // StripByteCounts
        ]
        let entryCount = fixed.count + 1                          // + StripOffsets (273)
        let stripOffset = ifdOffset + 2 + entryCount * 12 + 4

        var entries = fixed
        entries.append((273, 4, 1, stripOffset))                  // StripOffsets
        entries.sort { $0.tag < $1.tag }

        var bytes: [UInt8] = [0x49, 0x49] + u16(42) + u32(ifdOffset)
        bytes += u16(entryCount)
        for entry in entries {
            bytes += u16(entry.tag) + u16(entry.type) + u32(entry.count) + u32(entry.value)
        }
        bytes += u32(0)                                            // no next IFD
        bytes += Array(encoded.data)
        return Data(bytes)
    }

    // MARK: buffer helpers (C1: real width, never the row stride)

    /// 8-bit RGB copy of `image`, drawn into a `width × height` context — the upscale step for
    /// the coarser fg/bg layers. `interpolation` overrides the context's default when given.
    private static func rgbBuffer(of image: CGImage, width: Int, height: Int,
                                  interpolation: CGInterpolationQuality?) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if let interpolation { ctx.interpolationQuality = interpolation }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let o = y * width * 3 + x * 3, s = x * 4
                pixels[o] = row[s]; pixels[o + 1] = row[s + 1]; pixels[o + 2] = row[s + 2]
            }
        }
        return pixels
    }

    /// 8-bit grey copy of `image`, drawn into a `width × height` DeviceGray context — used for
    /// the mask, which is already at that size, so this is a format conversion, not a resample.
    private static func greyBuffer(of image: CGImage, width: Int, height: Int,
                                   interpolation: CGInterpolationQuality?) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        if let interpolation { ctx.interpolationQuality = interpolation }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width { pixels[y * width + x] = row[x] }
        }
        return pixels
    }
}
