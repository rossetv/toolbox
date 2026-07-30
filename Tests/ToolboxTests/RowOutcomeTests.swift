// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// `RowOutcome` is the compound per-file result of the unified queue's single pass (spec §6.3):
/// one file can be compressed AND made searchable, which a flat, mutually exclusive outcome enum
/// could not express. These tests pin the shape every later task builds on — the derived `grew` and
/// `isDegraded` rules, and above all the runner-up descriptor's independence from which variant
/// won the size gate (spec §5's R7 reversal: keying retention on the winner is the asymmetry the
/// redesign removes).
final class RowOutcomeTests: XCTestCase {

    // MARK: derived size facts

    /// `grew` is derived, never stored: the compress leg can only ever shrink a file, but the OCR
    /// append adds content the user asked for and can push the delivered file past the input
    /// (spec §6.3). Strictly greater — a byte-identical result did not grow.
    func testGrewIsDerivedFromFinalBytes() {
        let shrunk = RowOutcome(originalBytes: 1_000, finalBytes: 400,
                                compress: .compressed(before: 1_000, after: 400))
        XCTAssertFalse(shrunk.grew)

        let grewAfterOCR = RowOutcome(originalBytes: 12_400_000, finalBytes: 13_100_000,
                                      compress: .compressed(before: 12_400_000, after: 11_900_000),
                                      ocr: .added(pages: 48, skipped: 0))
        XCTAssertTrue(grewAfterOCR.grew)

        let unchanged = RowOutcome(originalBytes: 9_000, finalBytes: 9_000,
                                   ocr: .added(pages: 3, skipped: 1))
        XCTAssertFalse(unchanged.grew, "an unchanged size is not growth")
    }

    // MARK: runner-up descriptor

    /// The descriptor describes the PARKED loser, whichever leg won. A hybrid winner parks the
    /// plain-gs output; a gs winner parks the hybrid (the R7 reversal); a bloated gs leg parks the
    /// untouched input. All three must be representable, and the descriptor must never be
    /// inferable from `shippedVariant` — the consent sheet and the versions capsule key on the
    /// descriptor's presence alone.
    func testRunnerUpDescriptorIndependentOfWinner() {
        let hybridWon = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                   compress: .compressed(before: 9_000, after: 2_000),
                                   shippedVariant: .mrc,
                                   runnerUp: RetainedVariant(kind: .plain, bytes: 3_000,
                                                             searchable: false))
        XCTAssertEqual(hybridWon.shippedVariant, .mrc)
        XCTAssertEqual(hybridWon.runnerUp?.kind, .plain)

        let gsWon = RowOutcome(originalBytes: 9_000, finalBytes: 2_500,
                               compress: .compressed(before: 9_000, after: 2_500),
                               shippedVariant: .plain,
                               runnerUp: RetainedVariant(kind: .mrc, bytes: 4_000,
                                                         searchable: true))
        XCTAssertEqual(gsWon.shippedVariant, .plain)
        XCTAssertEqual(gsWon.runnerUp?.kind, .mrc,
                       "a hybrid that lost the size gate is still retained (spec §5)")

        let originalParked = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                        compress: .compressed(before: 9_000, after: 2_000),
                                        shippedVariant: .mrc,
                                        runnerUp: RetainedVariant(kind: .original, bytes: 9_000,
                                                                  searchable: false))
        XCTAssertEqual(originalParked.runnerUp?.kind, .original)

        let noRetention = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                     compress: .compressed(before: 9_000, after: 2_000),
                                     shippedVariant: .plain)
        XCTAssertNil(noRetention.runnerUp)
    }

    // MARK: leg outcomes

    /// One leg can be skipped by a problem while the other runs (spec §6.3): the compress-failure
    /// rescue delivers an OCR-only file and carries the problem that caused it, which is what the
    /// warn row's copy and history's systemic-failure signal read.
    func testSkippedProblemCase() {
        let rescued = RowOutcome(originalBytes: 9_000, finalBytes: 9_400,
                                 compress: .skipped(problem: .compressFailed),
                                 ocr: .added(pages: 12, skipped: 0))
        XCTAssertEqual(rescued.compress, .skipped(problem: .compressFailed))
        XCTAssertEqual(rescued.ocr, .added(pages: 12, skipped: 0))

        // The full problem vocabulary is representable in the same position.
        for problem in [RowProblem.locked, .missing, .unreadable, .compressFailed] {
            XCTAssertEqual(RowOutcome(originalBytes: 1, finalBytes: 1,
                                      compress: .skipped(problem: problem)).compress,
                           .skipped(problem: problem))
        }
    }

    /// "The verb was off" and "the verb ran and was cancelled between the legs" are different
    /// facts about the delivered file: the first carries no searchability claim at all, the second
    /// is the honestly-labelled banked row of spec §6.5. `nil` must never stand in for `.cancelled`.
    func testCancelledOCRDistinctFromNil() {
        let compressOnly = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                      compress: .compressed(before: 9_000, after: 2_000))
        let cancelledBetweenLegs = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                              compress: .compressed(before: 9_000, after: 2_000),
                                              ocr: .cancelled)
        XCTAssertNil(compressOnly.ocr)
        XCTAssertEqual(cancelledBetweenLegs.ocr, .cancelled)
        XCTAssertNotEqual(compressOnly, cancelledBetweenLegs)
    }

    // MARK: warn/degraded classification

    /// The spec's warn partition (§6.5): a rescued row, a too-faint read, a cancelled read and a
    /// failed read are all DEGRADED — a delivered file with an honest caveat, never a failed row
    /// ("Files that failed were not touched at all" must stay true). Everything else is a clean
    /// finish.
    func testIsDegradedPartition() {
        let rescued = RowOutcome(originalBytes: 9_000, finalBytes: 9_400,
                                 compress: .skipped(problem: .compressFailed),
                                 ocr: .added(pages: 12, skipped: 0))
        XCTAssertTrue(rescued.isDegraded)

        let tooFaint = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                  compress: .compressed(before: 9_000, after: 2_000),
                                  ocr: .tooFaint)
        XCTAssertTrue(tooFaint.isDegraded)

        let cancelled = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                   compress: .compressed(before: 9_000, after: 2_000),
                                   ocr: .cancelled)
        XCTAssertTrue(cancelled.isDegraded)

        let readFailed = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                    compress: .compressed(before: 9_000, after: 2_000),
                                    ocr: .failed("Couldn't read this file"))
        XCTAssertTrue(readFailed.isDegraded,
                      "a recognition failure on a DELIVERED file degrades the row, never fails it")

        let compressedOnly = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                        compress: .compressed(before: 9_000, after: 2_000))
        XCTAssertFalse(compressedOnly.isDegraded)

        let noGain = RowOutcome(originalBytes: 9_000, finalBytes: 9_000,
                                compress: .noGain(bytes: 9_000))
        XCTAssertFalse(noGain.isDegraded)

        let both = RowOutcome(originalBytes: 9_000, finalBytes: 2_400,
                              compress: .compressed(before: 9_000, after: 2_000),
                              ocr: .added(pages: 4, skipped: 1))
        XCTAssertFalse(both.isDegraded)

        let alreadySearchable = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                           compress: .compressed(before: 9_000, after: 2_000),
                                           ocr: .alreadySearchable)
        XCTAssertFalse(alreadySearchable.isDegraded)

        // An append failure is shown through the variant labels (§6.4), never as a degraded row.
        let appendFailedElsewhere = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                                               compress: .compressed(before: 9_000, after: 2_000),
                                               ocr: .added(pages: 4, skipped: 0),
                                               runnerUp: RetainedVariant(kind: .plain, bytes: 3_000,
                                                                         searchable: false))
        XCTAssertFalse(appendFailedElsewhere.isDegraded)
    }

    // MARK: equality

    /// Every field participates in equality — the queue publishes `JobState.done(RowOutcome)` and
    /// a row whose runner-up bytes changed underneath it is a different row.
    func testEquatable() {
        let base = RowOutcome(originalBytes: 9_000, finalBytes: 2_000,
                              compress: .compressed(before: 9_000, after: 2_000),
                              ocr: .added(pages: 4, skipped: 1),
                              shippedVariant: .mrc,
                              runnerUp: RetainedVariant(kind: .plain, bytes: 3_000,
                                                        searchable: true))
        var twin = base
        XCTAssertEqual(base, twin)

        twin.finalBytes = 2_100
        XCTAssertNotEqual(base, twin, "the committed re-stat changes the row")

        var differentCompress = base
        differentCompress.compress = .noGain(bytes: 9_000)
        XCTAssertNotEqual(base, differentCompress)

        var differentOCR = base
        differentOCR.ocr = .tooFaint
        XCTAssertNotEqual(base, differentOCR)

        var differentWinner = base
        differentWinner.shippedVariant = .plain
        XCTAssertNotEqual(base, differentWinner)

        // `RetainedVariant.bytes` is mutable on purpose: the commit step re-stats every variant a
        // job appended a text layer to, and the pre-append number would be the wrong number.
        var restated = base
        restated.runnerUp?.bytes = 3_400
        XCTAssertNotEqual(base, restated)

        var relabelled = base
        relabelled.runnerUp?.searchable = false
        XCTAssertNotEqual(base, relabelled)

        XCTAssertNotEqual(JobState.done(base), JobState.done(restated))
    }
}
