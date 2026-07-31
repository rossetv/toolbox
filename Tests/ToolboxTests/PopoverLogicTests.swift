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

    // MARK: ChangeQualitySheet

    /// An OCR-only row (compress verb off, so `outcome.compress == nil`) has nothing this sheet
    /// can price or re-run, regardless of whether a `VersionStore` entry exists for it (spec
    /// §6.5) — matches `recompressState`'s own `case nil, .skipped: return .none` arming rule.
    func testChangeQualityEligibilityExcludesOCROnlyRow() {
        XCTAssertFalse(ChangeQualitySheet.isEligible(compress: nil, hasVersionsRecorded: true),
                       "an OCR-only row must not be eligible even though it has a VersionStore entry")
        XCTAssertFalse(ChangeQualitySheet.isEligible(compress: nil, hasVersionsRecorded: false))
    }

    /// A rescued row (compress `.skipped`) is likewise ineligible.
    func testChangeQualityEligibilityExcludesSkippedRow() {
        XCTAssertFalse(ChangeQualitySheet.isEligible(compress: .skipped(problem: .compressFailed),
                                                      hasVersionsRecorded: false))
    }

    /// A `.compressed` or `.noGain` row stays eligible as long as a `VersionStore` entry exists —
    /// `.noGain` has no `shipped` version either, but it can still be re-run at a new preset.
    func testChangeQualityEligibilityIncludesCompressedAndNoGainRows() {
        XCTAssertTrue(ChangeQualitySheet.isEligible(compress: .compressed(before: 100, after: 50),
                                                     hasVersionsRecorded: true))
        XCTAssertTrue(ChangeQualitySheet.isEligible(compress: .noGain(bytes: 100), hasVersionsRecorded: true))
    }

    /// A rescue with no `VersionStore` entry at all (nothing to price/re-run from) stays
    /// ineligible even if it somehow reported a compress outcome.
    func testChangeQualityEligibilityRequiresVersionsRecorded() {
        XCTAssertFalse(ChangeQualitySheet.isEligible(compress: .compressed(before: 100, after: 50),
                                                      hasVersionsRecorded: false))
    }

    private func rowSummary(currentBytes: Int, ownPreset: CompressPreset,
                            predictions: [CompressPreset: Int] = [:],
                            isExcluded: Bool = false) -> ChangeQualitySheet.RowSummary {
        ChangeQualitySheet.RowSummary(currentBytes: currentBytes, ownPreset: ownPreset,
                                      prediction: { predictions[$0] }, isExcluded: isExcluded)
    }

    /// The render's own numbers (screen 08): current total 10.4 MB (Balanced), Smallest predicts
    /// 6.2 MB, High quality predicts 23.0 MB.
    func testChangeQualityTotalsMatchRenderFigures() {
        let mb = 1_000_000
        let rows = [
            rowSummary(currentBytes: Int(4.1 * Double(mb)), ownPreset: .balanced,
                      predictions: [.smallestSize: Int(2.4 * Double(mb)), .maximumQuality: Int(8.9 * Double(mb))]),
            rowSummary(currentBytes: Int(6.1 * Double(mb)), ownPreset: .balanced,
                      predictions: [.smallestSize: Int(3.6 * Double(mb)), .maximumQuality: Int(13.9 * Double(mb))]),
            rowSummary(currentBytes: 184_000, ownPreset: .balanced,
                      predictions: [.smallestSize: 184_000, .maximumQuality: 184_000]),
        ]
        XCTAssertEqual(ChangeQualitySheet.total(rows, at: nil), rows.reduce(0) { $0 + $1.currentBytes })
        XCTAssertEqual(ChangeQualitySheet.total(rows, at: .balanced), rows.reduce(0) { $0 + $1.currentBytes })
    }

    /// A row already at the candidate preset contributes its EXACT current bytes, never a
    /// recomputed (and potentially drifted) estimate.
    func testChangeQualityTotalUsesActualBytesWhenAlreadyAtCandidate() {
        let rows = [rowSummary(currentBytes: 1000, ownPreset: .balanced, predictions: [.balanced: 999])]
        XCTAssertEqual(ChangeQualitySheet.total(rows, at: .balanced), 1000)
    }

    /// An excluded row ("Choose which files…") never moves, regardless of candidate.
    func testChangeQualityTotalSkipsExcludedRows() {
        let rows = [rowSummary(currentBytes: 1000, ownPreset: .balanced,
                              predictions: [.smallestSize: 400], isExcluded: true)]
        XCTAssertEqual(ChangeQualitySheet.total(rows, at: .smallestSize), 1000)
    }

    func testChangeQualityDeltaCurrentPresetReadsWhatYouHave() {
        let delta = ChangeQualitySheet.delta(current: 1000, candidate: 1000, presetIsMaximumQuality: false)
        XCTAssertEqual(delta.text, "what you have")
        XCTAssertEqual(delta.tone, .muted)
    }

    func testChangeQualityDeltaSmallerReadsGreenLess() {
        let delta = ChangeQualitySheet.delta(current: 1000, candidate: 600, presetIsMaximumQuality: false)
        XCTAssertTrue(delta.text.hasSuffix("less"))
        XCTAssertEqual(delta.tone, .success)
    }

    /// Maximum quality's larger total always reads its aspirational tagline, never a raw delta —
    /// it is the one preset in this trio nobody picks to save space.
    func testChangeQualityDeltaMaximumQualityReadsForPrinting() {
        let delta = ChangeQualitySheet.delta(current: 1000, candidate: 2300, presetIsMaximumQuality: true)
        XCTAssertEqual(delta.text, "for printing")
        XCTAssertEqual(delta.tone, .plain)
    }

    func testChangeQualityDeltaLargerNonMaximumReadsMore() {
        let delta = ChangeQualitySheet.delta(current: 1000, candidate: 1300, presetIsMaximumQuality: false)
        XCTAssertTrue(delta.text.hasSuffix("more"))
        XCTAssertEqual(delta.tone, .plain)
    }

    // MARK: ChangeQualitySheet mechanism lines

    func testMechanismLineArmedWithMeasuredDuration() {
        let line = ChangeQualitySheet.mechanismLine(state: .armed(.maximumQuality), preset: .maximumQuality,
                                                    measuredRate: 0.5, pageCount: 50)
        XCTAssertEqual(line, "Redone from the original at 300 DPI · about 25 seconds")
    }

    /// Duration source, pinned (spec §6.7 honest-progress rule): no measured rate → the
    /// mechanism line, never a fabricated duration.
    func testMechanismLineArmedWithoutMeasuredRateOmitsDuration() {
        let line = ChangeQualitySheet.mechanismLine(state: .armed(.balanced), preset: .balanced,
                                                    measuredRate: nil, pageCount: 50)
        XCTAssertEqual(line, "Redone from the original at 150 DPI")
    }

    func testMechanismLineInstantSwitch() {
        let line = ChangeQualitySheet.mechanismLine(state: .instantSwitch(.balanced), preset: .balanced,
                                                    measuredRate: nil, pageCount: nil)
        XCTAssertEqual(line, "Already on disk — swapped in immediately")
    }

    func testMechanismLineNoneAndFutileReadAlreadyOptimised() {
        XCTAssertEqual(ChangeQualitySheet.mechanismLine(state: .none, preset: .balanced,
                                                        measuredRate: nil, pageCount: nil),
                      "Already optimised — nothing to change")
        XCTAssertEqual(ChangeQualitySheet.mechanismLine(state: .futile(.balanced), preset: .balanced,
                                                        measuredRate: nil, pageCount: nil),
                      "Already optimised — nothing to change")
    }

    /// An excluded row ("Choose which files…" unticked it) is a different condition from a
    /// genuinely futile row — it must read "Not included", never borrow the futile caption.
    func testMechanismLineExcludedRowReadsNotIncludedRegardlessOfState() {
        XCTAssertEqual(ChangeQualitySheet.mechanismLine(state: .none, preset: .balanced,
                                                        measuredRate: nil, pageCount: nil, isExcluded: true),
                      "Not included")
        XCTAssertEqual(ChangeQualitySheet.mechanismLine(state: .armed(.balanced), preset: .balanced,
                                                        measuredRate: nil, pageCount: nil, isExcluded: true),
                      "Not included")
    }

    // MARK: ChangeQualitySheet size pinning / CTA gating (render 08 nothing-to-change rows)

    func testRowIsUnchangedForNoneAndFutileOnly() {
        XCTAssertTrue(ChangeQualitySheet.rowIsUnchanged(.none))
        XCTAssertTrue(ChangeQualitySheet.rowIsUnchanged(.futile(.balanced)))
        XCTAssertFalse(ChangeQualitySheet.rowIsUnchanged(.armed(.balanced)))
        XCTAssertFalse(ChangeQualitySheet.rowIsUnchanged(.instantSwitch(.balanced)))
    }

    /// The bug this fixes: a "nothing to change" row must never show a changed projection,
    /// even when a stale/different estimator prediction is available.
    func testRowTargetBytesPinsToCurrentWhenUnchanged() {
        XCTAssertEqual(ChangeQualitySheet.rowTargetBytes(state: .none, currentBytes: 66_000, prediction: 83_000),
                      66_000)
        XCTAssertEqual(ChangeQualitySheet.rowTargetBytes(state: .futile(.balanced), currentBytes: 184_000,
                                                         prediction: 200_000), 184_000)
    }

    func testRowTargetBytesUsesPredictionWhenChanged() {
        XCTAssertEqual(ChangeQualitySheet.rowTargetBytes(state: .armed(.balanced), currentBytes: 66_000,
                                                         prediction: 83_000), 83_000)
        // No confident estimate: falls back to current bytes, same as the footer's `total`.
        XCTAssertEqual(ChangeQualitySheet.rowTargetBytes(state: .armed(.balanced), currentBytes: 66_000,
                                                         prediction: nil), 66_000)
    }

    func testCanSwitchFalseWhenEveryRowIsUnchanged() {
        XCTAssertFalse(ChangeQualitySheet.canSwitch([.none, .futile(.balanced), .none]))
    }

    func testCanSwitchTrueWhenAnyRowWouldChange() {
        XCTAssertTrue(ChangeQualitySheet.canSwitch([.none, .armed(.smallestSize), .futile(.balanced)]))
    }

    // MARK: ScanConsentSheet

    func testScanConsentResolvedPairFindsMRCAndPlainEitherOrder() {
        let mrc = fileVersion(410_000, variant: .mrc)
        let plain = fileVersion(680_000, variant: .plain)

        // MRC shipped, plain parked as runner-up.
        var row = RowVersions(originalBytes: 1_870_000, lastAttemptPreset: .balanced,
                              shipped: mrc, runnerUp: plain, previous: nil)
        var resolved = ScanConsentSheet.resolvedPair(row: row)
        XCTAssertEqual(resolved?.mrc.url, mrc.url)
        XCTAssertEqual(resolved?.plain.url, plain.url)
        XCTAssertEqual(resolved?.shipped.url, mrc.url)

        // Plain shipped, MRC parked — the R7-reversal case (spec §5): still resolves, in the
        // other order.
        row = RowVersions(originalBytes: 1_870_000, lastAttemptPreset: .balanced,
                          shipped: plain, runnerUp: mrc, previous: nil)
        resolved = ScanConsentSheet.resolvedPair(row: row)
        XCTAssertEqual(resolved?.mrc.url, mrc.url)
        XCTAssertEqual(resolved?.plain.url, plain.url)
        XCTAssertEqual(resolved?.shipped.url, plain.url)
    }

    /// A withdrawn/mismatched pair — no runner-up, or a runner-up that isn't the {.mrc,.plain}
    /// shape — must not render a stale sheet.
    func testScanConsentResolvedPairNilWhenPairWithdrawn() {
        XCTAssertNil(ScanConsentSheet.resolvedPair(row: nil))

        let noRunnerUp = RowVersions(originalBytes: 1000, lastAttemptPreset: .balanced,
                                     shipped: fileVersion(400, variant: .mrc), runnerUp: nil, previous: nil)
        XCTAssertNil(ScanConsentSheet.resolvedPair(row: noRunnerUp))

        // Original-park pair (gs bloated, §6.3/§6.4) is not a rebuild-choice pair.
        let originalPark = RowVersions(originalBytes: 1000, lastAttemptPreset: .balanced,
                                       shipped: fileVersion(400, variant: .mrc),
                                       runnerUp: fileVersion(1000, variant: .original), previous: nil)
        XCTAssertNil(ScanConsentSheet.resolvedPair(row: originalPark))
    }

    func testScanConsentPercentTextNeverLies() {
        XCTAssertEqual(ScanConsentSheet.percentText(bytes: 410_000, originalBytes: 1_870_000), "78% smaller")
        // A variant that grew past the input states the truth rather than a nonsense negative
        // "smaller" figure (spec §7: "percentages never lie").
        XCTAssertEqual(ScanConsentSheet.percentText(bytes: 1_200_000, originalBytes: 1_000_000), "20% bigger")
        XCTAssertEqual(ScanConsentSheet.percentText(bytes: 1_000_000, originalBytes: 1_000_000), "same size")
    }

    /// Defensive: `.original` is not a pair `surfaceConsent` ever produces, but the copy
    /// functions must still be honest if fed it.
    func testScanConsentCopyHandlesOriginalKindHonestly() {
        XCTAssertFalse(ScanConsentSheet.variantTitle(.original).isEmpty)
        XCTAssertFalse(ScanConsentSheet.variantExplanation(.original).isEmpty)
        let badge = ScanConsentSheet.variantBadge(.original)
        XCTAssertFalse(badge.text.isEmpty)
    }

    func testScanConsentBadgesAreFixedByVariant() {
        XCTAssertEqual(ScanConsentSheet.variantBadge(.mrc).text, "BEST FOR SCANS")
        XCTAssertTrue(ScanConsentSheet.variantBadge(.mrc).isAccent)
        XCTAssertEqual(ScanConsentSheet.variantBadge(.plain).text, "NOTHING REDRAWN")
        XCTAssertFalse(ScanConsentSheet.variantBadge(.plain).isAccent)
    }

    // MARK: RecentBatchesSheet / EmptyStateView (F6b: successCount/failureNote)

    private func historyBatch(fileCount: Int = 3, presetTitle: String? = "Balanced",
                              compressOn: Bool = true, ocrOn: Bool = false,
                              savedBytes: Int = 21_200_000, searchableCount: Int = 0,
                              successCount: Int = 3, failureNote: String? = nil,
                              problem: Bool = false) -> HistoryBatch {
        HistoryBatch(folderName: "Contracts", folderURL: URL(fileURLWithPath: "/tmp/Contracts"),
                    fileCount: fileCount, presetTitle: presetTitle, compressOn: compressOn, ocrOn: ocrOn,
                    savedBytes: savedBytes, searchableCount: searchableCount,
                    successCount: successCount, failureNote: failureNote,
                    partial: false, problem: problem, cancelled: false)
    }

    func testRecentBatchesSubtitleComposesTimePresetAndSearchable() {
        let batch = historyBatch(fileCount: 3, searchableCount: 1)
        let subtitle = RecentBatchesSheet.subtitle(for: batch)
        XCTAssertTrue(subtitle.contains("Balanced"))
        XCTAssertTrue(subtitle.contains("one made searchable"))
    }

    func testRecentBatchesSubtitleOCROnlyReadsOCROnly() {
        let batch = historyBatch(fileCount: 12, presetTitle: nil, compressOn: false, ocrOn: true,
                                 savedBytes: 0, searchableCount: 12, successCount: 12)
        let subtitle = RecentBatchesSheet.subtitle(for: batch)
        XCTAssertTrue(subtitle.contains("OCR only"))
        XCTAssertTrue(subtitle.contains("all searchable"))
    }

    /// The handoff's screen-11 card copy ("14:22 · Smallest · one was password-locked") — the
    /// note IS the batch's own recorded failure cause, not a fabricated one.
    func testRecentBatchesSubtitleProblemReadsFailureNote() {
        let batch = historyBatch(fileCount: 5, successCount: 4, failureNote: "one was password-locked",
                                 problem: true)
        XCTAssertTrue(RecentBatchesSheet.subtitle(for: batch).contains("one was password-locked"))
    }

    /// A batch recorded before `failureNote` existed (on-disk schema predates F6b) decodes with
    /// `failureNote == nil` — the subtitle must still say SOMETHING honest, never crash or blank.
    func testRecentBatchesSubtitleProblemWithoutNoteFallsBackToGenericAttention() {
        let batch = historyBatch(failureNote: nil, problem: true)
        XCTAssertTrue(RecentBatchesSheet.subtitle(for: batch).contains("some files needed attention"))
    }

    /// Binding carry: an OCR-only/no-saving batch's trailing figure reads grey "no change",
    /// never a bare "0 MB".
    func testRecentBatchesSavedTextReadsNoChangeForZeroSavings() {
        XCTAssertEqual(RecentBatchesSheet.savedText(historyBatch(savedBytes: 0)), "no change")
        XCTAssertNotEqual(RecentBatchesSheet.savedText(historyBatch(savedBytes: 21_200_000)), "no change")
    }

    /// "4 of 5 files in Invoices" (screens 01/11): the title itself carries the success/total
    /// split — `HistoryBatch.displayTitle`, shared by both `RecentBatchesSheet.title(for:)` and
    /// `EmptyStateView`'s history-strip card.
    func testHistoryBatchDisplayTitleShowsSuccessOfTotalWhenSomeRowsDidNotDeliver() {
        let batch = historyBatch(fileCount: 5, successCount: 4)
        XCTAssertEqual(batch.displayTitle, "4 of 5 files in Contracts")
        XCTAssertEqual(RecentBatchesSheet.title(for: batch), "4 of 5 files in Contracts")
    }

    /// A clean batch (every row delivered) keeps the plain "M files in <folder>" line — no
    /// spurious "3 of 3".
    func testHistoryBatchDisplayTitleReadsPlainCountWhenEveryRowDelivered() {
        let batch = historyBatch(fileCount: 3, successCount: 3)
        XCTAssertEqual(batch.displayTitle, "3 files in Contracts")
    }

    /// The empty-state strip's own card copy (screen 01): "11:05 · one was password-locked" when
    /// the batch recorded a failure note, falling back to the generic line otherwise.
    func testEmptyStateSubtitleUsesFailureNoteWhenPresent() {
        let batch = historyBatch(failureNote: "one was password-locked", problem: true)
        XCTAssertTrue(EmptyStateView.subtitle(for: batch).contains("one was password-locked"))
    }

    func testEmptyStateSubtitleWithoutFailureNoteFallsBackToNeedsAttention() {
        let batch = historyBatch(failureNote: nil, problem: true)
        XCTAssertTrue(EmptyStateView.subtitle(for: batch).contains("needs attention"))
    }

    /// Screen 01's icon parallax is driven by the pointer's offset from the centre of the whole
    /// content area, normalised to ±1 — the handoff's own normalisation, which is what bounds the
    /// tilt to ±11°/±13° and the drift to ±7pt. A shipped build once fed this the 76pt icon frame
    /// instead of the stage, which put the input near ±5 and sheared the icon off its stack.
    func testEmptyStateParallaxNormalisesAgainstTheStageAndClamps() {
        let stage = CGSize(width: 900, height: 508)
        let centre = EmptyStateView.normalise(CGPoint(x: 450, y: 254), in: stage)
        XCTAssertEqual(centre.x, 0, accuracy: 0.0001)
        XCTAssertEqual(centre.y, 0, accuracy: 0.0001)

        let corner = EmptyStateView.normalise(CGPoint(x: 900, y: 0), in: stage)
        XCTAssertEqual(corner.x, 1, accuracy: 0.0001)
        XCTAssertEqual(corner.y, -1, accuracy: 0.0001)

        // `onContinuousHover` can report a location just outside the bounds; it must not push the
        // tilt past the handoff's envelope.
        let outside = EmptyStateView.normalise(CGPoint(x: 4000, y: -900), in: stage)
        XCTAssertEqual(outside.x, 1, accuracy: 0.0001)
        XCTAssertEqual(outside.y, -1, accuracy: 0.0001)

        // A zero-sized stage (first layout pass) must rest, not divide by zero.
        XCTAssertEqual(EmptyStateView.normalise(CGPoint(x: 10, y: 10), in: .zero), .zero)
    }

    func testRecentBatchesDayLabelTodayYesterdayAndOlder() {
        let calendar = Calendar.current
        let now = Date()
        XCTAssertEqual(RecentBatchesSheet.dayLabel(now, now: now, calendar: calendar), "TODAY")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(RecentBatchesSheet.dayLabel(yesterday, now: now, calendar: calendar), "YESTERDAY")
        let lastWeek = calendar.date(byAdding: .day, value: -8, to: now)!
        let label = RecentBatchesSheet.dayLabel(lastWeek, now: now, calendar: calendar)
        XCTAssertNotEqual(label, "TODAY")
        XCTAssertNotEqual(label, "YESTERDAY")
    }
}
