// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
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
    // Ordered smallest-to-largest output, matching the design mockup's left-to-right reading.
    case smallestSize
    case balanced
    case maximumQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximumQuality: return "High quality"
        case .balanced: return "Balanced"
        case .smallestSize: return "Smallest"
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
    /// Target DPI for colour/grey images — surfaced in the UI so the trade-off is concrete.
    var imageDPI: Int { colourDPI }

    private var colourDPI: Int {
        switch self {
        case .maximumQuality: return 300
        case .balanced: return 150
        case .smallestSize: return 100
        }
    }

    /// Bilevel/mono images keep a higher resolution (text edges) than contone images.
    /// Target DPI for bilevel/mono content — also the render resolution for the Rung-2 binarise.
    var bilevelDPI: Int { monoDPI }

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
            // Task 0 (Rung-3 spec D9): AutoFilter lets gs re-decide the codec per image and
            // silently ignore QFactor; explicit DCTEncode + the distiller-params QFactor is the
            // measured tuned baseline every Rung-3 margin is honest against.
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dGrayImageFilter=/DCTEncode",
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

    /// JPEG quantisation aggressiveness for re-encoded images (gs distiller QFactor; higher
    /// is smaller/rougher). Calibrated 2026-07-23 against real colour scans (anonymised
    /// aggregates only): balanced 1.5 is visually indistinguishable from the input at 100 %
    /// (≈30 % smaller); smallest 3.0 keeps text fully legible (≈46 % smaller); maximumQuality
    /// stays conservative — at 300 DPI targets the downsample threshold rarely triggers a
    /// re-encode, so the value seldom applies at all.
    var jpegQFactor: Double {
        switch self {
        case .maximumQuality: return 0.76
        case .balanced: return 1.5
        case .smallestSize: return 3.0
        }
    }

    /// PostScript fragment passed to gs via `-c` (a single argv element — no shell quoting),
    /// followed by `-f <input>`. Sets the JPEG quantisation both image dicts use; must come
    /// after every `-d`/`-s` switch and before the input file.
    func gsDistillerParams() -> String {
        let dict = "<< /QFactor \(jpegQFactor) /Blend 1 "
            + "/HSamples [2 1 1 2] /VSamples [2 1 1 2] >>"
        return "<< /ColorImageDict \(dict) /GrayImageDict \(dict) >> setdistillerparams"
    }
}
