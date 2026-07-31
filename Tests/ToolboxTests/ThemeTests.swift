// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import SwiftUI
import XCTest
@testable import Toolbox

/// Pins every handoff design token onto its Swift identifier (see the mapping comment atop
/// `Theme`). Dynamic `Color`s are resolved under a forced `NSAppearance` — `Color`/`NSColor`
/// carry no public "give me the light value" accessor, but a dynamic `NSColor`'s provider block
/// consults `NSAppearance.currentDrawing`, which `performAsCurrentDrawingAppearance` sets
/// deterministically regardless of the actual system appearance running the tests.
final class ThemeTests: XCTestCase {

    // MARK: - Colour resolution helper

    private func resolved(_ color: Color, _ appearance: NSAppearance.Name) -> (r: Double, g: Double, b: Double, a: Double) {
        let appearance = NSAppearance(named: appearance)!
        var resolvedColor: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor(color).usingColorSpace(.sRGB)
        }
        return (Double(resolvedColor.redComponent), Double(resolvedColor.greenComponent),
                Double(resolvedColor.blueComponent), Double(resolvedColor.alphaComponent))
    }

    private func assertColor(
        _ color: Color, light: (hex: UInt32, alpha: Double), dark: (hex: UInt32, alpha: Double),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let tolerance = 0.004   // ~1/255 — a single 8-bit rounding step
        let expectedLight = components(of: light.hex, alpha: light.alpha)
        let expectedDark = components(of: dark.hex, alpha: dark.alpha)
        let actualLight = resolved(color, .aqua)
        let actualDark = resolved(color, .darkAqua)

        XCTAssertEqual(actualLight.r, expectedLight.r, accuracy: tolerance, "light red", file: file, line: line)
        XCTAssertEqual(actualLight.g, expectedLight.g, accuracy: tolerance, "light green", file: file, line: line)
        XCTAssertEqual(actualLight.b, expectedLight.b, accuracy: tolerance, "light blue", file: file, line: line)
        XCTAssertEqual(actualLight.a, expectedLight.a, accuracy: tolerance, "light alpha", file: file, line: line)

        XCTAssertEqual(actualDark.r, expectedDark.r, accuracy: tolerance, "dark red", file: file, line: line)
        XCTAssertEqual(actualDark.g, expectedDark.g, accuracy: tolerance, "dark green", file: file, line: line)
        XCTAssertEqual(actualDark.b, expectedDark.b, accuracy: tolerance, "dark blue", file: file, line: line)
        XCTAssertEqual(actualDark.a, expectedDark.a, accuracy: tolerance, "dark alpha", file: file, line: line)
    }

    private func components(of hex: UInt32, alpha: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        (Double((hex >> 16) & 0xFF) / 255.0, Double((hex >> 8) & 0xFF) / 255.0, Double(hex & 0xFF) / 255.0, alpha)
    }

    // MARK: - Colours re-valued onto existing identifiers (handoff bg/text2/text3/accent/success)

    func testBackgroundMatchesHandoffBgIncludingTheDarkRevalue() {
        assertColor(Theme.Colors.background, light: (0xF5F5F7, 1), dark: (0x1C1C1E, 1))
    }

    func testSurfaceMatchesHandoffSurfaceIncludingTheDarkRevalue() {
        assertColor(Theme.Colors.surface, light: (0xFFFFFF, 1), dark: (0x24_24_26, 1))
    }

    func testAccentMatchesHandoffAccentIncludingTheNewDarkVariant() {
        assertColor(Theme.Colors.accent, light: (0x0071E3, 1), dark: (0x0A84FF, 1))
    }

    func testSuccessMatchesHandoffSuccessIncludingTheNewDarkVariant() {
        assertColor(Theme.Colors.success, light: (0x34C759, 1), dark: (0x32D74B, 1))
    }

    func testTextSecondaryMatchesHandoffText2() {
        assertColor(Theme.Colors.textSecondary, light: (0x000000, 0.8), dark: (0xFFFFFF, 0.8))
    }

    func testTextTertiaryMatchesHandoffText3() {
        assertColor(Theme.Colors.textTertiary, light: (0x000000, 0.48), dark: (0xFFFFFF, 0.48))
    }

    func testLinkMatchesHandoffLink() {
        assertColor(Theme.Colors.link, light: (0x0066CC, 1), dark: (0x2997FF, 1))
    }

    // MARK: - Colours: NEW identifiers (no incumbent)

    func testWarnMatchesHandoffWarnIdenticalInBothAppearances() {
        assertColor(Theme.Colors.warn, light: (0xFF9F0A, 1), dark: (0xFF9F0A, 1))
    }

    func testDangerMatchesHandoffDanger() {
        assertColor(Theme.Colors.danger, light: (0xD70015, 1), dark: (0xFF453A, 1))
    }

    func testStrokeMatchesHandoffStroke() {
        assertColor(Theme.Colors.stroke, light: (0x000000, 0.168), dark: (0xFFFFFF, 0.168))
    }

    func testSepMatchesHandoffSep() {
        assertColor(Theme.Colors.sep, light: (0x000000, 0.12), dark: (0xFFFFFF, 0.12))
    }

    func testHairlineMatchesHandoffHairline() {
        assertColor(Theme.Colors.hairline, light: (0x000000, 0.096), dark: (0xFFFFFF, 0.096))
    }

    /// `fill` is deliberately asymmetric — an off-black tint at 6% light, plain white at 10%
    /// dark — not a black/white mirror like `stroke`/`sep`/`hairline`.
    func testFillMatchesHandoffFillAsymmetricAcrossAppearances() {
        assertColor(Theme.Colors.fill, light: (0x1D1D1F, 0.06), dark: (0xFFFFFF, 0.1))
    }

    func testTrackMatchesHandoffTrack() {
        assertColor(Theme.Colors.track, light: (0x1D1D1F, 0.12), dark: (0xFFFFFF, 0.12))
    }

    // MARK: - Radii

    func testPillIsTheHandoffCapsuleValueUnchanged() {
        XCTAssertEqual(Theme.Radius.pill, 980)
    }

    func testCardIsTheHandoffPopoverValueUnchanged() {
        XCTAssertEqual(Theme.Radius.card, 12)
    }

    func testControlIsUnchanged() {
        XCTAssertEqual(Theme.Radius.control, 8)
    }

    func testRowIsTheHandoffValue() {
        XCTAssertEqual(Theme.Radius.row, 10)
    }

    func testSheetIsTheHandoffValue() {
        XCTAssertEqual(Theme.Radius.sheet, 14)
    }

    // MARK: - Typography: the incumbent `caption` re-valued to the handoff's 11.5

    func testCaptionIsRevaluedToTheHandoffSize() {
        XCTAssertEqual(Theme.Typography.caption.font, Font.system(size: 11.5, weight: .regular))
        XCTAssertEqual(Theme.Typography.caption.tracking, -0.2, accuracy: 0.0001)
    }

    // MARK: - Typography: NEW cases

    func testWindowHeadline() {
        XCTAssertEqual(Theme.Typography.windowHeadline.font, Font.system(size: 22, weight: .semibold))
        XCTAssertEqual(Theme.Typography.windowHeadline.tracking, -0.3, accuracy: 0.0001)
    }

    func testSheetTitle() {
        XCTAssertEqual(Theme.Typography.sheetTitle.font, Font.system(size: 17, weight: .semibold))
        XCTAssertEqual(Theme.Typography.sheetTitle.tracking, -0.2, accuracy: 0.0001)
    }

    func testRowName() {
        XCTAssertEqual(Theme.Typography.rowName.font, Font.system(size: 15, weight: .semibold))
        XCTAssertEqual(Theme.Typography.rowName.tracking, -0.2, accuracy: 0.0001)
    }

    func testBodyStrong() {
        XCTAssertEqual(Theme.Typography.bodyStrong.font, Font.system(size: 13, weight: .semibold))
        XCTAssertEqual(Theme.Typography.bodyStrong.tracking, -0.2, accuracy: 0.0001)
    }

    func testBody13() {
        XCTAssertEqual(Theme.Typography.body13.font, Font.system(size: 13, weight: .regular))
        XCTAssertEqual(Theme.Typography.body13.tracking, -0.2, accuracy: 0.0001)
    }

    func testMeta() {
        XCTAssertEqual(Theme.Typography.meta.font, Font.system(size: 12, weight: .regular))
        XCTAssertEqual(Theme.Typography.meta.tracking, -0.2, accuracy: 0.0001)
    }

    /// `meta` (12) and `caption` (11.5) must not collapse to the same size — that would make two
    /// of the seven new/re-valued roles indistinguishable.
    func testMetaAndCaptionAreDistinctSizes() {
        XCTAssertNotEqual(Theme.Typography.meta.font, Theme.Typography.caption.font)
    }

    func testSectionLabel() {
        XCTAssertEqual(Theme.Typography.sectionLabel.font, Font.system(size: 11, weight: .semibold))
        XCTAssertEqual(Theme.Typography.sectionLabel.tracking, 0.4, accuracy: 0.0001)
    }

    // MARK: - Motion

    func testStandardSpringMatchesTheHandoffCurveEquivalent() {
        XCTAssertEqual(Theme.Motion.standardResponse, 0.35, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.standardDamping, 0.85, accuracy: 0.0001)
    }

    func testDurations() {
        XCTAssertEqual(Theme.Motion.hover, 0.15, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.press, 0.12, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.popover, 0.3, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.sheet, 0.38, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.banner, 0.45, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.checkPop, 0.45, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.capGlow, 1.6, accuracy: 0.0001)
    }

    /// The handoff's per-control hover/active CSS (DESIGN.md §8): `opacity:.9` +
    /// `translateY(-1px)` on hover, `scale(.97)` on press, `opacity:.6` on text links.
    func testTransformValues() {
        XCTAssertEqual(Theme.Motion.hoverOpacity, 0.9, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.hoverLift, -1, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.pressScale, 0.97, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.linkHoverOpacity, 0.6, accuracy: 0.0001)
    }

    // MARK: - Reduce Motion gates
    //
    // Nil-ness, not `Animation` equality: `Animation` carries no useful `Equatable` semantics for
    // this (which is why `standardResponse`/`standardDamping` are pinned as Doubles above).

    func testCurvesAreNilUnderReduceMotion() {
        XCTAssertNil(Theme.Motion.hoverCurve(reduceMotion: true))
        XCTAssertNil(Theme.Motion.pressCurve(reduceMotion: true))
        XCTAssertNil(Theme.Motion.standardCurve(reduceMotion: true))

        XCTAssertNotNil(Theme.Motion.hoverCurve(reduceMotion: false))
        XCTAssertNotNil(Theme.Motion.pressCurve(reduceMotion: false))
        XCTAssertNotNil(Theme.Motion.standardCurve(reduceMotion: false))
    }

    func testPressScaleFlattensUnderReduceMotion() {
        XCTAssertEqual(Theme.Motion.scale(isPressed: true, reduceMotion: false), Theme.Motion.pressScale, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.scale(isPressed: false, reduceMotion: false), 1, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.scale(isPressed: true, reduceMotion: true), 1, accuracy: 0.0001)
    }

    /// A pressed control sits back at rest even while the pointer is still over it — the
    /// handoff's active rule is `transform:translateY(0) scale(.97)`, not a lifted press.
    func testHoverLiftReturnsToRestWhenPressedOrReducedMotion() {
        XCTAssertEqual(Theme.Motion.lift(isHovering: true, reduceMotion: false), Theme.Motion.hoverLift, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.lift(isHovering: false, reduceMotion: false), 0, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.lift(isHovering: true, isPressed: true, reduceMotion: false), 0, accuracy: 0.0001)
        XCTAssertEqual(Theme.Motion.lift(isHovering: true, reduceMotion: true), 0, accuracy: 0.0001)
    }
}
