// Tests/ToolboxTests/CompressPresetTests.swift
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Toolbox

final class CompressPresetTests: XCTestCase {

    /// Task 0 pins explicit JPEG encoding: gs's AutoFilter would silently re-decide the codec
    /// and ignore any QFactor we set, so both AutoFilter switches must be off and the filter
    /// forced to DCTEncode for every preset.
    func testEveryPresetDisablesAutoFilterAndForcesDCTEncode() {
        for preset in CompressPreset.allCases {
            let args = preset.gsArguments()
            XCTAssertTrue(args.contains("-dAutoFilterColorImages=false"), preset.rawValue)
            XCTAssertTrue(args.contains("-dAutoFilterGrayImages=false"), preset.rawValue)
            XCTAssertTrue(args.contains("-dColorImageFilter=/DCTEncode"), preset.rawValue)
            XCTAssertTrue(args.contains("-dGrayImageFilter=/DCTEncode"), preset.rawValue)
        }
    }

    /// Full-array snapshots: any argument drift is a deliberate, test-visible decision.
    func testBalancedArgumentSnapshot() {
        XCTAssertEqual(CompressPreset.balanced.gsArguments(), [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dPDFSETTINGS=/ebook",
            "-dDownsampleColorImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=150",
            "-dDownsampleGrayImages=true",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=150",
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=300",
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dGrayImageFilter=/DCTEncode",
            "-dSubsetFonts=true",
            "-dCompressFonts=true",
            "-dDetectDuplicateImages=true",
            "-dFastWebView=true",
            "-dConvertCMYKImagesToRGB=true",
        ])
    }

    /// Full-array snapshot for `.smallestSize` (/screen, 100 DPI colour/grey, 300 DPI mono,
    /// QFactor flags identical, CMYK still converted).
    func testSmallestSizeArgumentSnapshot() {
        XCTAssertEqual(CompressPreset.smallestSize.gsArguments(), [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dPDFSETTINGS=/screen",
            "-dDownsampleColorImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=100",
            "-dDownsampleGrayImages=true",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=100",
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=300",
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dGrayImageFilter=/DCTEncode",
            "-dSubsetFonts=true",
            "-dCompressFonts=true",
            "-dDetectDuplicateImages=true",
            "-dFastWebView=true",
            "-dConvertCMYKImagesToRGB=true",
        ])
    }

    /// Full-array snapshot for `.maximumQuality` (/printer, 300 DPI colour/grey, 600 DPI mono,
    /// QFactor flags identical, no CMYK conversion — preserves print intent).
    func testMaximumQualityArgumentSnapshot() {
        XCTAssertEqual(CompressPreset.maximumQuality.gsArguments(), [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dPDFSETTINGS=/printer",
            "-dDownsampleColorImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=300",
            "-dDownsampleGrayImages=true",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=300",
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=600",
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dGrayImageFilter=/DCTEncode",
            "-dSubsetFonts=true",
            "-dCompressFonts=true",
            "-dDetectDuplicateImages=true",
            "-dFastWebView=true",
        ])
    }

    /// The distiller-params fragment carries the per-preset QFactor into both image dicts.
    func testDistillerParamsCarryPresetQFactor() {
        for preset in CompressPreset.allCases {
            let ps = preset.gsDistillerParams()
            let q = "/QFactor \(preset.jpegQFactor)"
            XCTAssertEqual(ps.components(separatedBy: q).count, 3,
                           "\(preset.rawValue): QFactor must appear in ColorImageDict and GrayImageDict")
            XCTAssertTrue(ps.hasSuffix("setdistillerparams"))
            XCTAssertTrue(ps.contains("/ColorImageDict"))
            XCTAssertTrue(ps.contains("/GrayImageDict"))
        }
    }

    /// Ordering guarantee the engine relies on: QFactor tightens monotonically from
    /// maximumQuality to smallestSize.
    func testQFactorOrdering() {
        XCTAssertLessThan(CompressPreset.maximumQuality.jpegQFactor, CompressPreset.balanced.jpegQFactor)
        XCTAssertLessThanOrEqual(CompressPreset.balanced.jpegQFactor, CompressPreset.smallestSize.jpegQFactor)
    }
}
