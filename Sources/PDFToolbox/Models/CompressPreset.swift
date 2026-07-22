// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The three compression presets (spec §5.2), each mapping to a tuned Ghostscript
/// `pdfwrite` argument set.
///
/// This is a **concrete provisional baseline** (plan `[m1]`/`[m2]`, from the engine
/// research): a base `-dPDFSETTINGS` level, explicit Bicubic colour/grey downsampling to a
/// per-preset target DPI, font subsetting/compression, duplicate-image detection and
/// `FastWebView`. Exact DPI and JPEG QFactor are retuned against the real corpus in Task S.2.
/// CMYK is converted to RGB on the two smaller presets and preserved on `maximumQuality`
/// (avoids colour shift / broken print intent).
enum CompressPreset: String, CaseIterable, Identifiable {
    case maximumQuality
    case balanced
    case smallestSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximumQuality: return "High Quality"
        case .balanced: return "Balanced"
        case .smallestSize: return "Smallest Size"
        }
    }

    /// Base distiller preset level.
    private var pdfSettings: String {
        switch self {
        case .maximumQuality: return "/printer"
        case .balanced: return "/ebook"
        case .smallestSize: return "/screen"
        }
    }

    /// Target resolution for colour/grey image downsampling.
    private var colourDPI: Int {
        switch self {
        case .maximumQuality: return 300
        case .balanced: return 150
        case .smallestSize: return 100
        }
    }

    /// Bilevel/mono images keep a higher resolution (text edges) than contone images.
    private var monoDPI: Int {
        switch self {
        case .maximumQuality: return 600
        case .balanced: return 300
        case .smallestSize: return 300
        }
    }

    /// Whether CMYK images are converted to RGB (shrinks; only on the non-archival presets).
    private var convertCMYKToRGB: Bool { self != .maximumQuality }

    /// The gs arguments for this preset — device, settings and image handling only. The
    /// caller (`CompressEngine`) appends `-sOutputFile=…` and the input path.
    func gsArguments() -> [String] {
        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dPDFSETTINGS=\(pdfSettings)",
            // Colour images
            "-dDownsampleColorImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=\(colourDPI)",
            // Grey images
            "-dDownsampleGrayImages=true",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=\(colourDPI)",
            // Mono/bilevel images
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=\(monoDPI)",
            // Fonts + structure
            "-dSubsetFonts=true",
            "-dCompressFonts=true",
            "-dDetectDuplicateImages=true",
            "-dFastWebView=true",
        ]
        if convertCMYKToRGB {
            args.append("-dConvertCMYKImagesToRGB=true")
        }
        return args
    }
}
