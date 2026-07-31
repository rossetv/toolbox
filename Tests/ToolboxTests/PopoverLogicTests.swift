// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// The pure logic behind the popovers/sheets (Track P-B): every named function here is what a
/// SwiftUI body reads from, so asserting the function is asserting the screen without driving a
/// live view hierarchy — the same split `QueueViewModel` uses for its own static helpers
/// (`readingPageLabel`, `compressLegLabel`, `smoothedETA`).
@MainActor
final class PopoverLogicTests: XCTestCase {

    // MARK: QualityPopover

    func testQualityPopoverBatchTotalSumsPerPresetEstimates() {
        let rows = [
            QualityPopover.RowInput(overridePreset: nil, estimates: [
                .smallestSize: SizeEstimate(predictedBytes: 100, isFallback: false),
                .balanced: SizeEstimate(predictedBytes: 200, isFallback: false),
                .maximumQuality: SizeEstimate(predictedBytes: 400, isFallback: false),
            ]),
            QualityPopover.RowInput(overridePreset: nil, estimates: [
                .smallestSize: SizeEstimate(predictedBytes: 50, isFallback: false),
                .balanced: SizeEstimate(predictedBytes: 90, isFallback: false),
                .maximumQuality: SizeEstimate(predictedBytes: 180, isFallback: false),
            ]),
        ]
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .smallestSize), 150)
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .balanced), 290)
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .maximumQuality), 580)
    }

    /// An overridden row never moves off its own preset, whichever candidate the popover is
    /// asking about — the override always wins (spec §6.1).
    func testQualityPopoverBatchTotalRespectsRowOverrides() {
        let rows = [
            QualityPopover.RowInput(overridePreset: .maximumQuality, estimates: [
                .smallestSize: SizeEstimate(predictedBytes: 100, isFallback: false),
                .balanced: SizeEstimate(predictedBytes: 200, isFallback: false),
                .maximumQuality: SizeEstimate(predictedBytes: 400, isFallback: false),
            ]),
        ]
        // Asking about "Smallest" for the batch must not drag the overridden row along.
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .smallestSize), 400)
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .maximumQuality), 400)
    }

    /// A row whose analysis has not landed yet (still time-boxed) contributes nothing — it must
    /// never block the rest of the batch's total from rendering.
    func testQualityPopoverBatchTotalSkipsMissingAnalysis() {
        let rows = [
            QualityPopover.RowInput(overridePreset: nil, estimates: nil),
            QualityPopover.RowInput(overridePreset: nil, estimates: [
                .balanced: SizeEstimate(predictedBytes: 200, isFallback: false),
            ]),
        ]
        XCTAssertEqual(QualityPopover.batchTotal(rows: rows, candidate: .balanced), 200)
    }

    // MARK: OCRPopover

    /// Vision's `.fast` recognition covers only the six Latin-script curated languages —
    /// Chinese, Japanese and Korean need `.accurate`. The popover must refuse Fast for exactly
    /// the same set the VM clamps, never a second, independently-maintained list.
    func testOCRPopoverDisablesFastForCJKLanguages() {
        for code in ["zh-Hans", "ja-JP", "ko-KR"] {
            XCTAssertTrue(OCRPopover.fastDisabled(languages: [code]),
                         "\(code) cannot be read at Fast")
        }
        XCTAssertTrue(OCRPopover.fastDisabled(languages: ["en-US", "ja-JP"]),
                     "one unsupported language is enough to disable Fast")
    }

    func testOCRPopoverLeavesFastEnabledForLatinScripts() {
        for code in ["en-US", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR"] {
            XCTAssertFalse(OCRPopover.fastDisabled(languages: [code]),
                          "\(code) reads fine at Fast")
        }
        XCTAssertFalse(OCRPopover.fastDisabled(languages: []), "auto-detect never disables Fast")
    }

    // MARK: PerFileSettingsPopover — rebuild-toggle domain (spec §7, pinned)

    func testRebuildToggleHiddenOnNonScanColourRows() {
        for contentType: PDFContentType? in [.bornDigital, .mixedColour, .scanBilevel, nil] {
            for preset in CompressPreset.allCases {
                XCTAssertEqual(
                    PerFileSettingsPopover.rebuildToggleDomain(contentType: contentType, preset: preset),
                    .hidden, "\(String(describing: contentType)) at \(preset) must hide the toggle")
            }
        }
    }

    func testRebuildToggleDisabledAtMaximumQuality() {
        XCTAssertEqual(
            PerFileSettingsPopover.rebuildToggleDomain(contentType: .scanColour, preset: .maximumQuality),
            .disabledAtMaximumQuality)
    }

    func testRebuildToggleEnabledOnScanColourBelowMaximumQuality() {
        XCTAssertEqual(
            PerFileSettingsPopover.rebuildToggleDomain(contentType: .scanColour, preset: .balanced), .enabled)
        XCTAssertEqual(
            PerFileSettingsPopover.rebuildToggleDomain(contentType: .scanColour, preset: .smallestSize), .enabled)
    }

    // MARK: VersionsPopoverContent

    /// Spec §6.4's honest-label requirement, composed exactly (Global Constraints' recorded
    /// divergence, owner P-B): the fixed subtitle drops its terminal full stop and appends the
    /// claim; no OCR claim leaves the design copy untouched, stop and all.
    func testComposedSubtitleAppendsSearchableClaim() {
        XCTAssertEqual(
            VersionsPopoverContent.composedSubtitle(
                base: "Never modified, still in its folder.", searchable: true),
            "Never modified, still in its folder · Searchable")
    }

    func testComposedSubtitleAppendsNotSearchableClaim() {
        XCTAssertEqual(
            VersionsPopoverContent.composedSubtitle(
                base: "Never modified, still in its folder.", searchable: false),
            "Never modified, still in its folder · Not searchable")
    }

    func testComposedSubtitleLeavesDesignCopyUntouchedWhenOCRNeverRan() {
        XCTAssertEqual(
            VersionsPopoverContent.composedSubtitle(
                base: "Never modified, still in its folder.", searchable: nil),
            "Never modified, still in its folder.")
    }

    /// The card-title/description mapping stays honest even for `.original`, which
    /// `surfaceConsent` never actually pairs into this popover today — a defensive test of the
    /// pure function, not a reachable runtime state.
    func testCardCopyHandlesOriginalKindHonestly() {
        XCTAssertEqual(VersionsPopoverContent.cardTitle(bytes: 1_000_000, variant: .original),
                       "Original · 1 MB")
        XCTAssertFalse(VersionsPopoverContent.cardDescription(variant: .original, isShipped: false).isEmpty)
        XCTAssertTrue(VersionsPopoverContent.cardDescription(variant: .original, isShipped: true)
            .hasPrefix("In use."))
    }

    private func fileVersion(_ bytes: Int, variant: EngineVariant = .plain) -> FileVersion {
        FileVersion(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf"),
                   bytes: bytes, preset: .balanced, variant: variant)
    }

    /// Three highlight cases plus the disabled state (plan step 2's `testCompareVersionsPairSelection`).
    func testCompareVersionsPairSelection() {
        let shipped = fileVersion(100, variant: .mrc)
        let runnerUp = fileVersion(200, variant: .plain)
        let original = fileVersion(400, variant: .original)
        let cards: [(key: VersionCardKey, version: FileVersion)] = [
            (.shipped, shipped), (.runnerUp, runnerUp), (.originalReference, original),
        ]

        // No highlight yet: in-use + first parked.
        XCTAssertEqual(VersionsPopoverContent.compareVersionsPair(cards: cards, highlighted: nil)?.0,
                       shipped.url)
        XCTAssertEqual(VersionsPopoverContent.compareVersionsPair(cards: cards, highlighted: nil)?.1,
                       runnerUp.url)

        // The in-use row itself highlighted: same fallback, never "compare a file with itself".
        let selfHighlight = VersionsPopoverContent.compareVersionsPair(cards: cards, highlighted: .shipped)
        XCTAssertEqual(selfHighlight?.0, shipped.url)
        XCTAssertEqual(selfHighlight?.1, runnerUp.url)

        // A specific parked row highlighted: pairs with THAT row, not the first one.
        let originalHighlight = VersionsPopoverContent.compareVersionsPair(cards: cards, highlighted: .originalReference)
        XCTAssertEqual(originalHighlight?.0, shipped.url)
        XCTAssertEqual(originalHighlight?.1, original.url)

        // Disabled: only one file on this row at all.
        XCTAssertNil(VersionsPopoverContent.compareVersionsPair(
            cards: [(.shipped, shipped)], highlighted: nil))
    }

    // MARK: model-level wiring

    /// Tapping the already-in-use card is inert (`useCard`'s `.shipped` arm is a documented
    /// no-op) — a model-level test, since the popover's own tap handler always calls through.
    func testUseCardOnShippedRowIsInert() async throws {
        let env = try HeavyEnv()
        let job = try await env.runToDone()
        let before = env.model.versions(for: job)
        XCTAssertNotNil(before)
        await env.model.useCard(.shipped, for: job)
        XCTAssertEqual(env.model.versions(for: job), before)
    }

}
