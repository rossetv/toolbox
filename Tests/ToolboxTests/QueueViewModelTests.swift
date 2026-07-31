// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import XCTest
@testable import Toolbox

// MARK: - R-net re-derivation map (spec §11; plan Task P-D)
//
// The redesign reverses prior-art rules this suite was written to defend (spec §5's change
// table), so every test it carried has to be re-derived rather than assumed still meaningful.
// This is that enumeration: all 62 test funcs present at the redesign's base commit 624d398 —
// `grep -c 'func test'` on `CompressViewModelTests.swift`, the file this one was renamed from,
// a count that INCLUDES the three untagged funcs preceding the first `// MARK:` — each with
// the disposition it now stands at, plus the siblings added since.
//
// DERIVATION, not recollection. Dispositions come from per-commit BODY diffs
// (`git show -M --unified=0 <sha> -- <path>`, each hunk mapped onto its enclosing func), and
// the cross-suite sweep at the foot comes from grepping the MECHANISM's symbols —
// `runTask == nil`, `isRunning`, `alternateOutput`, `switchesInFlight`, `compressedHeavy`,
// `canCompress` — never the R-tags in the MARK headings. An R-tag records which rule a group
// was written for; it does not record whether the redesign moved it, and three of the four
// reversals below sit in groups whose heading names no rule that changed.
//
//   adapt             the invariant survives; the body changed only to track a renamed symbol
//                     or a new mechanism, or did not change at all
//   superseded-by(X)  the assertion no longer exists here; X carries the invariant forward
//   flipped-by(F<n>)  the asserted BEHAVIOUR itself was reversed by that task
//   new(F<n>)         sibling added by that task
//
// TALLIES, reconciled against the rows below (`git log` for 647fd8c carries an earlier count
// that did not add to 62 — these are the numbers, and the derivation is in the rows):
//   of the 62 at base: 3 superseded · 5 body-adapted · 54 carried unchanged  (3 + 5 + 54 = 62)
//   flipped: 3 — ONE inside this file (`testAddIsIgnoredWhileABatchIsRunning`, which is also one
//     of the three superseded) and TWO cross-suite (`ToolQueueTests.testAddWhileRunningIsRefused`,
//     `CompressEngineMRCTests.testHybridLargerThanGsShipsGsOutput`)
//   new siblings: 3 already landed (F1b ×2, F4 ×1) + 4 filled by P-D
//   the 5 body-adapted: testThreeFileSyntheticBatchCompressesEndToEnd ·
//     testCompressIsRefusedWhileASwitchIsInFlight · testMixedRunCountsBothSets ·
//     testArmedRowsAloneEnableTheButton · testAPlainResultWithAPreviousVersionOffersTheCapsule
//
// Task keys: F1 ecb3968 · F1b 8f803b7 · F2 cc3c3cb · F4 a256405 + d46511a + 1e1aa74 ·
// F5a 08fc827 · F5e f45dc19 · F6 a630def · P-D (this task).
//
// F4's rename commit (a256405) rewrote every func in the file. Its diff filtered on
// `CompressViewModel` → `QueueViewModel` is EMPTY, so it changed no assertion and is not
// recorded per row.
//
// === untagged early block (3 at base) ===
//   testAddIsIgnoredWhileABatchIsRunning ....... flipped-by(F4) → superseded-by(
//                                               QueueAdmissionTests.testAddDuringRunJoinsBatch);
//                                               tombstoned in place at the head of the class body
//   testThreeFileSyntheticBatchCompressesEndToEnd ... adapt — F1 destructures the compound
//                                               outcome, F4 `canCompress` → `canStart`,
//                                               F6 injects a temp-rooted `HistoryStore`
//   testChangingPresetReestimatesQueuedJobs .... adapt (body unchanged)
//   testCJKLanguageClampsAccuracyToAccurate .... new(F4)
//
// === MARK: runner-up switch + lifecycle (Task 18) — 21 at base ===
// (3 + 21 + 5 + 4 + 12 + 5 + 3 + 3 + 4 + 2 = 62, the base count derived above.)
// The spec's R7-asymmetry reversal is an ENGINE change (F2): it decides WHICH variants reach a
// row, never how the row switches between the ones it has. Every switch invariant below is
// therefore intact, and the group needed no flips.
//   testCompressedHeavyOutcomePublishesBothVersions ... adapt (body unchanged)
//   testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize ... adapt (body unchanged) — the
//                                               `runnerUpBytes == inputSize` marker F2's
//                                               withhold rule deliberately exempts
//   testCompressedHeavyRetainsMRCReportOnJob ... adapt (body unchanged)
//   testSecondUseVersionTapWhileFirstIsInFlightIsANoOp ... adapt (body unchanged)
//   testSwitchTogglesInstantlyAndReversibly .... adapt (body unchanged)
//   testPlainSwitchNeverExposesARunningRowOrDropsAllFinished ... adapt (body unchanged)
//   testCapsuleTitleFlipsOnSwitch ............. superseded-by(testShippedCardFlipsOnSwitch)
//                                               (F1b) — `capsuleTitle` became the "N versions"
//                                               family, so the honest-label invariant moved
//                                               onto the popover's shipped card
//   testCapsuleTitleReadsOriginalWhenRunnerUpIsInput ... superseded-by(
//                                               testCardsSurfaceOriginalKindParkedVariant) (F1b)
//   testShippedCardFlipsOnSwitch .............. new(F1b), amended by F5a (the always-present
//                                               Original reference row takes the row to three)
//   testCardsSurfaceOriginalKindParkedVariant .. new(F1b)
//   testSavedBytesUsesShippedVersionForHeavyJob ... adapt (body unchanged)
//   testDisplayedBytesTracksShippedVersion ..... adapt (body unchanged)
//   testSwitchWithMissingRunnerUpRerunsJob ..... adapt (body unchanged) — the re-run path it
//                                               drives was rebuilt by F5e; the invariant it
//                                               asserts (a vanished runner-up is regenerated,
//                                               not silently dropped) is unchanged, and F5e's
//                                               own additions live in `QueuePassTests`
//   testUseVersionIsIgnoredWhileARunIsInFlight .. adapt (body unchanged)
//   testCompressIsRefusedWhileASwitchIsInFlight . adapt — F4 `canCompress` → `canStart`
//   testClearFinishedRefusedWhileASwitchIsInFlight ... adapt (body unchanged)
//   testSwitchFailingAfterRerunLeavesStateCanonical ... adapt (body unchanged)
//   testRerunSwitchClearsAStaleRecompressErrorOnSuccess ... adapt (body unchanged)
//   testLaterBatchDoesNotRewriteAFinishedRowsPreset ... adapt (body unchanged) — spec §5 keeps
//                                               this one BY NAME through the per-row override
//                                               reversal; `effectivePreset` equals the batch
//                                               preset on a row with no override
//   testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling ... adapt (unchanged)
//   testRemoveRowDiscardsRunnerUp ............. adapt (body unchanged)
//   testClearFinishedDiscardsRunnerUps ........ adapt (body unchanged)
//   testCancelDiscardsRunnerUpReservations .... adapt (body unchanged)
//
// === MARK: arming (R1/R3/R6/R7) — 5 at base ===
// F4 step 5 re-keyed arming and futility onto `effectivePreset(for:)`/`effectiveVerbs(for:)`.
// None of these five needed a body change: with no override the effective preset IS the batch
// preset, so each still asserts its own invariant. Their per-row siblings are F4's
// `QueueAdmissionTests.testArmingUsesRowEffectivePreset` and `testFutilityKeyIncludesVerbSet`,
// and P-D's `testFutilityIsKeyedByTheRowsEffectivePresetNotTheBatchs` below.
//   testSelectingADifferentPresetArmsAFinishedRow ... adapt (body unchanged)
//   testReselectingTheRowsPresetDisarmsIt ..... adapt (body unchanged)
//   testFailedRowsNeverArm .................... adapt (body unchanged)
//   testNoGainRowArmsElsewhereAndIsFutileAtItsOwnPreset ... adapt (body unchanged)
//   testNothingArmsWhileARunIsInFlight ........ adapt (body unchanged)
//   testFutilityIsKeyedByTheRowsEffectivePresetNotTheBatchs ... new(P-D)
//
// === MARK: recompress prediction (R16) — 4 at base ===
// R16's calibration gate is the engine's own `wantsMRC` conjunction, and the redesign ADDED a
// third term to it: the row's `rebuildScan` override. The two path tests below predate that
// term and exercise only the preset term, hence P-D's sibling.
//   testPredictionScalesByTheObservedRatioWhenThePathRepeats ... adapt (body unchanged)
//   testPredictionUsesTheRawEstimateWhenTheEnginePathChanges ... adapt (body unchanged)
//   testPredictionIsWithheldWhenItWouldNotBeatTheOriginal ... adapt (body unchanged)
//   testPredictionIsWithheldWhenTheOriginalIsGone ... adapt (body unchanged)
//   testPredictionTakesTheRawEstimateWhenTheRowsRebuildIsOptedOut ... new(P-D)
//
// === MARK: recompress commit protocol (R10–R13) — 12 at base ===
// F5e rebuilt `recompress`'s engine call (OCR re-applied, row `rebuildScan` honoured, commit
// through `replaceItemAt`, `finalBytes` re-stat). Its new assertions live in `QueuePassTests`;
// every commit-protocol invariant here survives unchanged, because R10–R13 govern WHERE the
// result lands and WHAT is parked, neither of which the reversals touch.
//   testRecompressCommitsAndParksThePreviousVersion ... adapt (body unchanged)
//   testRecompressDeliversTheFreshResultWhenTheShippedFileWasDeletedOutsideTheApp ... adapt
//   testPreviousVersionsPresetOffersAnInstantSwitchRatherThanArming ... adapt (unchanged)
//   testRecompressFailureKeepsThePreviousVersionAndReportsIt ... adapt (body unchanged)
//   testARecompressErrorClearsWhenThePresetChangesOrTheNextRunStarts ... adapt (unchanged)
//   testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase ... adapt (unchanged)
//   testCancellingARecompressKeepsThePreviousResult ... adapt (body unchanged)
//   testNoGainRecompressKeepsEveryReference ... adapt (body unchanged)
//   testRecompressWritesToTheRowsExistingResultPathAfterTheFolderChanged ... adapt (unchanged)
//   testAQueuedJobNeverClaimsAnArmedRowsResultPath ... adapt (body unchanged) — the reservation
//                                               ledger moved to add time (F4), and this still
//                                               asserts the collision it was written for
//   testAQueuedJobNeverClaimsAnExistingRowsLiveRunnerUpPath ... adapt (body unchanged)
//   testMissingOriginalReportsPerRowAndLeavesTheResultIntact ... adapt (body unchanged)
//   testARecompressKeepsARetainedRunnerUpWhileParkingThePrevious ... new(P-D)
//
// === MARK: one run, two phases (R5/R9) — 5 at base ===
//   testMixedRunCountsBothSets ................ adapt — F4 `canCompress` → `canStart`
//   testArmedRowsAloneEnableTheButton ......... adapt — F4 `canCompress` → `canStart`
//   testTheRecompressPhaseWaitsForTheQueuePhase ... adapt (body unchanged)
//   testRunProgressIsScopedToTheRunsOwnRows ... adapt (body unchanged)
//   testAFailedQueuedRowStillCountsTowardTheProgressBar ... adapt (body unchanged)
//
// === MARK: armed-state aggregates and cache lifecycle (R4/R17/R18) — 3 at base ===
//   testAllFinishedIsFalseWhileARowIsArmed .... adapt (body unchanged)
//   testClearFinishedDiscardsTheParkedPreviousVersion ... adapt (body unchanged)
//   testAPlainResultWithAPreviousVersionOffersTheCapsule ... adapt — F1b moved the capsule to
//                                               the "N versions" family, F5a took the row to
//                                               three cards; the GATE it pins (a parked slot,
//                                               never the card count) is unchanged
//
// === MARK: the armed banner's arithmetic (R4) — 3 at base ===
//   testArmedSummarySumsThePredictedExtraSaving ... adapt (body unchanged)
//   testArmedSummaryGoesNonPositiveWhenTheArmedPresetIsLessAggressive ... adapt (unchanged)
//   testArmedSummaryWithholdsTheExtraWhenNoRowPredictsConfidently ... adapt (unchanged)
//   testArmedSummaryPricesAnOverriddenRowAtItsOwnPreset ... new(P-D)
//
// === MARK: the previous version, end to end (R7/R15) — 4 at base ===
// The R7 in this heading is RECOMPRESS R7 (the previous-version slot), not MRC R7 (the
// discarded losing hybrid). Only the latter is reversed — the tag-grep trap this map exists
// to avoid.
//   testUsingThePreviousVersionSwapsTheDeliveredFileBack ... adapt (body unchanged)
//   testUsingAVanishedPreviousVersionReportsItAndDropsTheSlot ... adapt (body unchanged)
//   testAFailedSwitchKeepsAPreviousVersionThatIsStillOnDisk ... adapt (body unchanged)
//   testAFailedRunnerUpSwitchKeepsTheRunnerUpThatIsStillOnDisk ... adapt (body unchanged)
//
// === MARK: lead derivation (R2/R6/R10/R12) — 2 at base ===
//   testANoGainRowIsBothUnchangedAndArmed ..... adapt (body unchanged)
//   testAnArmedRowWithAMissingOriginalOffersNoPrediction ... adapt (body unchanged)
//
// === cross-suite: every test elsewhere whose asserted behaviour this spec reverses ===
// Located by the mechanism greps above, not by rule tags. Each disposition below was VERIFIED
// against the commit that owns it; the flips are their owners' work, recorded here so the
// re-derivation is complete in one place.
//
//   `alternateOutput` — CompressEngineMRCTests (F2 owns all eight; verified landed):
//     testHybridLargerThanGsShipsGsOutput ..... flipped-by(F2) → superseded-by(
//                                               testHybridLostGateStillWritesRunnerUp).
//                                               It asserted `alternateOutput` was NOT written
//                                               when the hybrid lost — the exact R7 asymmetry
//                                               spec §5 removes
//     testHybridSmallerThanGsShipsHybridWithRunnerUp ......... adapt — hybrid-won retention was
//                                               already symmetric; body changed only for F2's
//                                               `ReportSpy` count refactor
//     testHybridWinsButGsCandidateNotSmallerThanInputParksOriginalAsRunnerUp ... adapt — the
//                                               untouched-original park is not a compress
//                                               artefact, so §6.3's withhold rule spares it
//                                               (DECISIONS 2026-07-24)
//     testMRCInternalFailureShipsGsSilently ... adapt — no valid hybrid exists, so retention
//                                               cannot fire
//     testNeverLargerThanInputStillHolds ...... adapt — no-gain path, nothing to retain
//     testScanColourOnMaximumQualityNeverAttemptsMRC ......... adapt — no hybrid built (D3)
//     testScanBilevelStillRoutesToRungTwo ..... adapt — no hybrid built
//     testCancelDuringRungThreeDeliversNoOutput ............... adapt — body untouched by F2
//   MRCInvariantTests.testEndToEndMixedDocumentBeatsGs ....... adapt — the hybrid WINS there,
//                                               and the winning path always retained its loser
//
//   `isRunning` / the add-time guard — F4 owns both flips (verified landed):
//     ToolQueueTests.testAddWhileRunningIsRefused ............. flipped-by(F4) → superseded-by(
//                                               testAddDuringRunJoinsTheLiveBatch), the
//                                               queue-level half; tombstoned in that file
//     QueueViewModelTests.testAddIsIgnoredWhileABatchIsRunning ... see the untagged block above
//   ToolQueueTests.testSecondRunIsRefusedSoTheLiveBatchStaysCancellable ... adapt — the `run`
//                                               re-entrancy guard is NOT the add guard and is
//                                               deliberately untouched (plan F4)
//
//   `switchesInFlight` — no reversal: the switch guard's semantics are unchanged by the spec, and
//                                               its only consumer outside this file is
//                                               `QueuePassTests`, written by F5a/F5b/F5e AFTER
//                                               the reversals landed — it cannot be asserting the
//                                               old behaviour. All adapt.
//
//   Checked and INERT — the two files `grep -rln isRunning Tests/` returns that no row above
//   accounts for. Named so the sweep is re-runnable: a reader repeating that grep gets five
//   files and must be able to tell a null result from an omission.
//     `BatchProgressTests` ..................... created by F5c (bb45372), after every reversal,
//                                               so it cannot assert pre-reversal behaviour; its
//                                               `isRunning` hits are `waitUntil` conditions, not
//                                               assertions
//     `SeatbeltRunTests` ....................... homonym: every hit is `Foundation.Process`'s own
//                                               `isRunning` on the gs child, not the view model's.
//                                               Untouched since 624d398, and the seatbelt scope is
//                                               a KEPT constraint (spec §5), not a reversed one
//
//   Recompress R19 (OCR gains no recompress behaviour) — reversed by F5e. No test asserted R19
//                                               anywhere: the mechanism grep returns only two
//                                               `Sources/` comments and no assertion, so the
//                                               reversal's whole test surface is F5e's new
//                                               `QueuePassTests` re-run block. (One of those
//                                               comments is now a stale claim — reported to the
//                                               orchestrator, not fixed here: no `Sources/`
//                                               edits in this track.)
//
// === gaps this task filled (4) ===
// Each is a rule that survives R1–R18 but whose mechanism the redesign changed underneath it,
// leaving the rule asserted only against the pre-redesign shape. Every one was seen to FAIL
// against a deliberately broken assertion before being committed — the suite is green by
// construction here, so a test that has never been red is a test that proves nothing.
//   testFutilityIsKeyedByTheRowsEffectivePresetNotTheBatchs — R6 futility, preset axis, per row
//   testPredictionTakesTheRawEstimateWhenTheRowsRebuildIsOptedOut — R16 calibration, the
//     `rebuildScan` term the redesign added to the path test
//   testArmedSummaryPricesAnOverriddenRowAtItsOwnPreset — R4 banner arithmetic, per row
//   testARecompressKeepsARetainedRunnerUpWhileParkingThePrevious — spec §5's version-cap
//     collision driven end to end through the view model (`VersionStoreTests`'
//     `testConsentRetentionPlusPreviousParkStaysWithinCap` proves it at the store)

/// Drives `QueueViewModel` exactly as the view does — the full batch/preset/estimate/
/// output-folder GUI path (Track C, Task C.2), end to end, with no UI harness involved (the
/// view itself has no logic beyond calling into this model).
@MainActor
final class QueueViewModelTests: XCTestCase {

    // `testAddIsIgnoredWhileABatchIsRunning` lived here. It asserted the OLD add-time guard —
    // names were reserved in a serial pass at run start, so a file dropped mid-batch would run
    // unreserved. Reservation moved to add time (spec §6.5), so the drop now JOINS the batch:
    // SUPERSEDED by `QueueAdmissionTests.testAddDuringRunJoinsBatch`.

    /// Vision's `.fast` recognition supports only the six Latin-script entries of
    /// `OCROptions.curatedLanguages` — Chinese, Japanese and Korean need `.accurate` (recorded on
    /// `OCROptions` itself, read from `supportedRecognitionLanguages()`). A Fast + CJK request
    /// either fails or reads nothing, so the pairing is clamped at the view model's own options
    /// surface, where the user sees the control snap back rather than being quietly overridden
    /// deeper down.
    func testCJKLanguageClampsAccuracyToAccurate() throws {
        let model = QueueViewModel(engine: nil)

        for code in ["zh-Hans", "ja-JP", "ko-KR"] {
            model.ocrOptions = OCROptions(accuracy: .fast, languages: [code])
            XCTAssertEqual(model.ocrOptions.accuracy, .accurate,
                           "\(code) cannot be read at Fast, so the request must not claim it will")
            XCTAssertEqual(model.ocrOptions.languages, [code], "only the accuracy is clamped")
        }

        // A mixed selection still clamps — one unsupported language is enough to make Fast a lie.
        model.ocrOptions = OCROptions(accuracy: .fast, languages: ["en-US", "ja-JP"])
        XCTAssertEqual(model.ocrOptions.accuracy, .accurate)

        // And a Latin-only Fast request is left exactly as the user set it.
        model.ocrOptions = OCROptions(accuracy: .fast, languages: ["en-US", "fr-FR"])
        XCTAssertEqual(model.ocrOptions.accuracy, .fast)
    }

    func testThreeFileSyntheticBatchCompressesEndToEnd() async throws {
        // A temp-rooted history store: this test drives a real `compress()` through the
        // production entry point, and a history entry must never land in the developer's own
        // `~/Library/Application Support/Toolbox/history.json`.
        let historyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        let model = QueueViewModel(history: HistoryStore(directory: historyRoot))
        XCTAssertNil(model.loadError, "Ghostscript should resolve from the test host bundle")

        // Three distinct basenames: a shared output folder collision-avoidance race between
        // same-named concurrent jobs is a separate, pre-existing FileNaming concern (reported
        // separately) — this test proves the batch/estimate/preset/output-folder path C.2 owns.
        // (bilevelPDF() is deliberately avoided here too — compressing it through the real
        // engine at .balanced fails OutputValidator's blank-page check, a second separate
        // pre-existing issue in the shared CompressEngine/OutputValidator/Fixtures path,
        // reproduced standalone and reported rather than fixed here.)
        let inputs = [try Fixtures.imagePDF(), try Fixtures.textImagePDF(), try Fixtures.bornDigitalPDF()]
        let outputFolder = inputs[0].deletingLastPathComponent()
        model.outputFolder = outputFolder

        model.add(inputs)
        try await waitUntil(timeout: 5) { model.jobs.count == 3 }

        // Every queued job should pick up a (possibly fallback) estimate promptly — the
        // estimator is time-boxed to 500 ms, so this should settle well inside 5 s for 3 files.
        try await waitUntil(timeout: 5) {
            model.jobs.allSatisfy { $0.estimate != nil }
        }
        for job in model.jobs {
            XCTAssertNotNil(job.estimate)
            XCTAssertGreaterThan(job.estimate!.predictedBytes, 0)
        }

        XCTAssertTrue(model.canStart)
        model.compress()
        XCTAssertTrue(model.isRunning)

        try await waitUntil(timeout: 30) {
            model.jobs.allSatisfy { if case .queued = $0.state { return false }
                                     if case .analysing = $0.state { return false }
                                     if case .running = $0.state { return false }
                                     return true }
        }
        try await waitUntil(timeout: 5) { !model.isRunning }

        // Every job reached a terminal, real (queue-driven) outcome — not a leftover estimate.
        for job in model.jobs {
            switch job.state {
            case .done(let outcome):
                switch outcome.compress {
                case .compressed(let before, let after):
                    XCTAssertGreaterThan(before, 0)
                    XCTAssertGreaterThan(after, 0)
                    XCTAssertLessThan(after, before)
                case .noGain:
                    break   // the tiny born-digital fixture may legitimately not shrink
                default:
                    XCTFail("expected a compressed or no-gain leg, got \(outcome)")
                }
            case .failed(let message):
                XCTFail("job for \(job.url.lastPathComponent) failed: \(message)")
            default:
                XCTFail("expected a terminal state, got \(job.state)")
            }
        }

        // Output landed in the chosen folder, one file per input, named "-compressed".
        for input in inputs {
            let expected = outputFolder.appendingPathComponent(
                "\(input.deletingPathExtension().lastPathComponent)-compressed.pdf")
            let job = try XCTUnwrap(model.jobs.first { $0.url == input })
            if case .done(let outcome) = job.state, case .compressed = outcome.compress {
                XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                              "expected compressed output at \(expected.path)")
            }
        }
    }

    func testChangingPresetReestimatesQueuedJobs() async throws {
        let model = QueueViewModel()
        let input = try Fixtures.imagePDF()
        model.add([input])

        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        let balancedEstimate = try XCTUnwrap(model.jobs.first?.estimate)

        model.preset = .smallestSize
        // The preset change invalidates the old estimate; wait for a fresh one under the
        // new preset (the model briefly clears to .analysing then repopulates `estimate`).
        try await waitUntil(timeout: 5) {
            guard let job = model.jobs.first else { return false }
            guard let estimate = job.estimate else { return false }
            return estimate.predictedBytes != balancedEstimate.predictedBytes || estimate.isFallback
        }
    }

    // MARK: runner-up switch + lifecycle (Task 18)

    /// A `.compressedHeavy` outcome surfaces both versions through `versions(for:)`, with the
    /// heavy version shipped by default (R7/R8).
    func testCompressedHeavyOutcomePublishesBothVersions() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.shipped?.variant == .mrc)
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant == .mrc })?.version.bytes),
                       HeavyEnv.heavyBytes)
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant != .mrc })?.version.bytes),
                       HeavyEnv.normalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(versions.shipped?.url).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(versions.runnerUp?.url).path))
        XCTAssertFalse(versions.runnerUp?.variant == .original,
                       "a gs runner-up smaller than the input is not the original")
    }

    /// When the engine parked the ORIGINAL instead of a gs runner-up (gs bloated, so
    /// `runnerUpBytes == before` — R6/R7 field fix), `versions(for:)` must mark it so the
    /// popover labels that card "Original" rather than "Normal".
    func testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize() async throws {
        let env = try HeavyEnv(before: HeavyEnv.normalBytes)
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.runnerUp?.variant == .original)
    }

    /// A report the engine hands back via the `mrcReport` closure is retained on the job result
    /// (spec §5/§6's debugging record), not discarded.
    func testCompressedHeavyRetainsMRCReportOnJob() async throws {
        let env = try HeavyEnv()
        let expectedReport = MRCDocumentReport(verdicts: [.mrcEncoded(MRCPageFeatures(
            inkCoverage: 0.4, meanComponentSize: 12, componentCount: 30, colourCoverage: 0.1,
            moderateChromaCoverage: 0.1
        ))])
        env.stub.reportToDeliver = expectedReport
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        XCTAssertEqual(job.mrcReport, expectedReport)
    }

    /// A second tap before the first switch lands must be a no-op, not a second concurrent swap on
    /// the same paths. `useVersion` sets its re-entrancy guard (`switchesInFlight`) synchronously,
    /// before `store.switchVersions`'s first suspension point, so the two MainActor tasks below can
    /// race for real without needing an artificial delay: the first runs its synchronous prefix to
    /// completion (setting the guard) before yielding, so the second observes the guard already set.
    func testSecondUseVersionTapWhileFirstIsInFlightIsANoOp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)

        async let first = model.useVersion(.runnerUp, for: job)
        async let second = model.useVersion(.runnerUp, for: job)
        _ = await (first, second)

        let switchedJob = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: switchedJob))
        XCTAssertEqual(versions.shipped?.variant, .plain,
                       "two concurrent taps must still land on exactly one switch, not cancel back out")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes,
                       "the shipped file must hold exactly one version's content, not a mangled swap")
        if case .failed = switchedJob.state {
            XCTFail("a raced second tap must never surface a false failure")
        }
    }

    /// The switch swaps the files in place and flips which version is shipped; a second switch
    /// restores the original state. The byte counts stay intrinsic to each version (R10).
    func testSwitchTogglesInstantlyAndReversibly() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        // The shipped file starts as the heavy version (our stub wrote `heavyBytes` there).
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertFalse(versions.shipped?.variant == .mrc, "after a switch the row ships the normal version")
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant == .mrc })?.version.bytes),
                       HeavyEnv.heavyBytes, "byte counts are intrinsic")
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant != .mrc })?.version.bytes),
                       HeavyEnv.normalBytes)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes,
                       "the shipped file now holds the normal version's content")

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.shipped?.variant == .mrc, "switching again restores the heavy version")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
    }

    /// A plain instant swap (the parked file still exists — no engine re-run) must render the row
    /// as finished throughout, never as a running job (R4/R7): `switchesInFlight` is only a
    /// re-entrancy guard, and `publishJobs()` must not treat guard membership alone as "busy" —
    /// only a genuine `rerunForSwitch` re-run (which populates `rerunProgress`) may do that.
    /// There is no seam to gate `performSwap`'s GCD hop (`RunnerUpStoreTests` doesn't gate it
    /// either), so this polls on a concurrent task instead of pausing mid-flight; `Task.yield()`
    /// gives the scheduler real opportunities to interleave and observe a corrupted frame if one
    /// existed.
    func testPlainSwitchNeverExposesARunningRowOrDropsAllFinished() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()
        let job = try XCTUnwrap(env.doneHeavyJob(model))

        let watchdog = Task { @MainActor () -> Bool in
            var corrupted = false
            while !Task.isCancelled {
                if env.doneHeavyJob(model) == nil { corrupted = true }
                if !model.allFinished { corrupted = true }
                await Task.yield()
            }
            return corrupted
        }

        await model.useVersion(.runnerUp, for: job)

        watchdog.cancel()
        let corrupted = try await watchdog.value
        XCTAssertFalse(corrupted,
                       "a plain swap must keep the row .done/.doneHeavy and allFinished true throughout")
    }

    /// The honest-label invariant the superseded `testCapsuleTitleFlipsOnSwitch` used to carry now
    /// lives on the popover's rows: the capsule only counts them, so a switch must flip the SHIPPED
    /// card's variant — the vocabulary `VersionsPopoverContent` renders per row.
    func testShippedCardFlipsOnSwitch() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.cards.first?.key, .shipped)
        XCTAssertEqual(versions.cards.first?.version.variant, .mrc)
        // Three from F5a on: the batch's commit records the untouched input, so the popover's
        // always-present Original reference row joins the pair (spec §6.4).
        XCTAssertEqual(versions.capsuleTitle, "3 versions")

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.cards.first?.version.variant, .plain,
                       "the parked version is a real gs output, not the untouched input")
        // The runner-up card BY KEY, not `cards.last`: the reference row is appended last now.
        XCTAssertEqual(versions.cards.first(where: { $0.key == .runnerUp })?.version.variant, .mrc,
                       "and the heavy version is now the parked one")
        XCTAssertEqual(versions.capsuleTitle, "3 versions")

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.cards.first?.version.variant, .mrc,
                       "switching back restores the heavy version to the shipped card")
        XCTAssertEqual(versions.capsuleTitle, "3 versions")
    }

    /// When the runner-up is the untouched original (R6/R7 field fix), the popover must surface it
    /// with its kind intact — `VersionsPopoverContent` labels that row "Original", and a `.plain`
    /// kind there would advertise a gs output that was never produced.
    func testCardsSurfaceOriginalKindParkedVariant() async throws {
        let env = try HeavyEnv(before: HeavyEnv.normalBytes)
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        let parked = try XCTUnwrap(versions.cards.first { $0.key == .runnerUp })
        XCTAssertEqual(parked.version.variant, .original,
                       "the parked file IS the input, and the card must say so")
        XCTAssertEqual(versions.capsuleTitle, "2 versions")

        await model.useVersion(.runnerUp, for: job)
        let switchedJob = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: switchedJob))
        XCTAssertFalse(versions.shipped?.variant == .mrc)
        XCTAssertEqual(versions.cards.first?.version.variant, .original,
                       "the kind travels with the bytes across the switch")
    }

    /// `displayedSizes(for:)` feeds the batch success banner's totals; for a `.compressedHeavy` job it
    /// must count the SHIPPED version's bytes, not always the heavy outcome's `after`, so a switch
    /// keeps the banner in sync with the row's own badge (sibling of the 730b67b badge fix).
    func testSavedBytesUsesShippedVersionForHeavyJob() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var saved = try XCTUnwrap(model.displayedSizes(for: job))
        XCTAssertEqual(saved.before, 9000)
        XCTAssertEqual(saved.after, HeavyEnv.heavyBytes,
                       "the heavy version ships by default, so it must be counted")

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        saved = try XCTUnwrap(model.displayedSizes(for: job))
        XCTAssertEqual(saved.after, HeavyEnv.normalBytes,
                       "after switching to normal, the banner totals must use the normal bytes")
    }

    /// The shipped version's byte count drives the row's size badge/percent (R10); it must track
    /// whichever version is actually shipped, not always the heavy one.
    func testDisplayedBytesTracksShippedVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.heavyBytes)

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.normalBytes,
                       "after switching to normal, the badge must show the normal version's bytes")

        await model.useVersion(.runnerUp, for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.heavyBytes,
                       "switching back must show the heavy version's bytes again")
    }

    /// When the runner-up file has vanished, the switch honestly re-runs the job (the row shows a
    /// running state) and, on completion, lands on the originally requested version (R10 tail).
    func testSwitchWithMissingRunnerUpRerunsJob() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // The runner-up leaves the cache; the next switch cannot swap and must re-run.
        try FileManager.default.removeItem(at: runnerUpURL)

        // Freeze the re-run mid-flight so the running state is observable, then release it.
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        await model.useVersion(.runnerUp, for: job)
        // Wait until the re-run has genuinely entered the engine (callCount bumped), then the row
        // must be in its running state and flagged as re-running.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.switchesInFlight.contains(job.id))
        if case .running = try XCTUnwrap(model.jobs.first).state {} else {
            XCTFail("the re-running row must show a running state")
        }

        await gate.open()
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(job.id) }

        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: settled))
        XCTAssertFalse(versions.shipped?.variant == .mrc,
                       "the re-run lands on the requested (normal) version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path),
                      "the re-run regenerated the runner-up")
        // With the refuse-overwrite stub, a switch that silently no-ops (R10's original bug) would
        // have thrown into the outer catch and left `shipped` holding its stale pre-rerun bytes —
        // assert the winning content genuinely landed, not just the bookkeeping flags.
        let shippedURL = try XCTUnwrap(settled.resultURL)
        let shippedData = try Data(contentsOf: shippedURL)
        let runnerUpData = try Data(contentsOf: runnerUpURL)
        XCTAssertEqual(shippedData, Data(repeating: 0x4E, count: HeavyEnv.normalBytes),
                       "the shipped file must hold the regenerated normal version's bytes")
        XCTAssertEqual(runnerUpData, Data(repeating: 0x48, count: HeavyEnv.heavyBytes),
                       "the runner-up slot must hold the regenerated heavy version's bytes")
    }

    /// R9's sixth mutating control: an armed row can still read `.doneHeavy` between `compress()`
    /// starting and phase 2 reaching it, so without the `isRunning` guard a switch here would race
    /// a second engine run against the in-flight run's own commit. Assert `useVersion` is a no-op
    /// for the whole run.
    func testUseVersionIsIgnoredWhileARunIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // Vanish the runner-up so a permitted switch would fall through to `rerunForSwitch` and
        // hit the engine — the exact second run the guard must prevent.
        try FileManager.default.removeItem(at: runnerUpURL)

        // A second row to occupy a genuinely in-flight run, gated so it stays mid-flight.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.isRunning)

        await model.useVersion(.runnerUp, for: job)
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "useVersion must not start a second engine run while a run is in flight")
        XCTAssertFalse(model.switchesInFlight.contains(job.id))

        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }
    }

    /// The symmetric guard: `compress()` must refuse while a switch's re-run is in flight, not just
    /// while `isRunning` is true — otherwise phase 2's promote would race the very shipped path an
    /// outstanding switch is still rewriting, and reservations would be handed out for paths that
    /// are transiently absent mid-swap (R9).
    func testCompressIsRefusedWhileASwitchIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // Vanish the runner-up so the switch falls through to `rerunForSwitch` and hits the engine,
        // and freeze that re-run mid-flight so `switchesInFlight` stays populated.
        try FileManager.default.removeItem(at: runnerUpURL)
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        async let switching = model.useVersion(.runnerUp, for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.switchesInFlight.contains(job.id))
        XCTAssertFalse(model.isRunning, "the switch's re-run, not a compress run, is in flight")

        // An armed/queued row present alongside the in-flight switch.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        XCTAssertFalse(model.canStart, "the footer button must disable, not silently no-op")

        model.compress()
        XCTAssertFalse(model.isRunning, "compress() must not start a run while a switch is in flight")
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the engine must not be invoked by the refused compress() call")

        await gate.open()
        _ = await switching
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(job.id) }

        // Now that the switch has landed, compress() must work again.
        XCTAssertTrue(model.canStart)
        let callsAfterSwitch = env.stub.callCount
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }
        try await waitUntil(timeout: 5) { env.stub.callCount > callsAfterSwitch }
        try await waitUntil(timeout: 5) { !model.isRunning }
    }

    /// A mid-switch row still shows/queues as `.done` (ec61602), so `clearFinished()` must refuse
    /// outright while a switch is in flight — otherwise it would discard the parked file the swap
    /// is mid-copy into.
    func testClearFinishedRefusedWhileASwitchIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // Vanish the runner-up so the switch falls through to `rerunForSwitch` and hits the
        // engine, and freeze that re-run mid-flight so `switchesInFlight` stays populated.
        try FileManager.default.removeItem(at: runnerUpURL)
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        async let switching = model.useVersion(.runnerUp, for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.switchesInFlight.contains(job.id))

        model.clearFinished()
        XCTAssertEqual(model.jobs.count, 1, "the row survives while its switch is in flight")
        XCTAssertNotNil(model.versions(for: job)?.runnerUp,
                         "the parked slot the re-run is regenerating must survive")
        XCTAssertNotNil(model.versions(for: job)?.shipped,
                         "the row's version record survives the refusal")

        await gate.open()
        _ = await switching
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(job.id) }

        // Now that the switch has landed, clearFinished() must work again.
        model.clearFinished()
        XCTAssertTrue(model.jobs.isEmpty)
    }

    /// If the runner-up vanished, the switch re-runs the job, but the *final* swap back into the
    /// switched state can still fail (store contract: a throw means `shipped` is unchanged). That
    /// must not be recorded as a switch — the row must stay canonical (heavy still shipped).
    func testSwitchFailingAfterRerunLeavesStateCanonical() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // The runner-up leaves the cache; the next switch cannot swap and must re-run.
        try FileManager.default.removeItem(at: runnerUpURL)

        // Freeze the re-run after it has rewritten both files, so the runner-up can be deleted
        // again from under it — the deterministic lever that makes the post-regeneration switch's
        // promote move fail (no file to move), the same failure mode `RunnerUpStoreTests`
        // (`testSwitchRestoresOnFailure`) exercises directly against the store.
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        await model.useVersion(.runnerUp, for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The stub has written both files and is now suspended on the gate — delete the runner-up
        // it just wrote before releasing it, so the switch that follows finds nothing to promote.
        try FileManager.default.removeItem(at: runnerUpURL)
        await gate.open()

        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(job.id) }

        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: settled))
        XCTAssertTrue(versions.shipped?.variant == .mrc,
                      "the failed post-regeneration switch must leave the row canonical (heavy shipped)")
        // The failed switch is an explicit button press that must not fail silently (R12) — the
        // row keeps a note explaining it, exactly like the instant-swap path's own failure message.
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Switch failed — kept your \(model.preset.title) version. Try again.")
    }

    /// A re-run switch that DOES land must clear any stale failure note left by a previous
    /// attempt on the same row — the re-run tail must clear `recompressErrors` exactly like the
    /// instant-swap success path already does (32380c4), never leaving a "try again" note beside
    /// a switch that just succeeded.
    func testRerunSwitchClearsAStaleRecompressErrorOnSuccess() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        try FileManager.default.removeItem(at: runnerUpURL)

        // First attempt: fail the post-regeneration swap exactly as the sibling test above, so a
        // failure note is recorded.
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount
        await model.useVersion(.runnerUp, for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        try FileManager.default.removeItem(at: runnerUpURL)
        await gate.open()
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(job.id) }
        XCTAssertNotNil(model.recompressErrors[job.id], "the failed attempt leaves its note")

        // Second attempt: the failed attempt deleted the runner-up itself (to force the failure
        // above), so it is still gone — this still re-runs, but nothing deletes the freshly
        // regenerated file this time, so the switch lands.
        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        await model.useVersion(.runnerUp, for: settled)
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(settled.id) }

        XCTAssertNil(model.recompressErrors[settled.id],
                     "a switch that lands must clear the previous attempt's failure note")
    }

    /// A second batch at a different preset must not rewrite what an ALREADY-FINISHED row was
    /// compressed under: `ToolQueue` only ever re-runs `.queued` jobs, so a finished row keeps its
    /// own preset, and the R10 re-run must reproduce that output rather than silently replacing the
    /// user's delivered file with a differently-compressed one.
    func testLaterBatchDoesNotRewriteAFinishedRowsPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .smallestSize
        try await env.runToDone()
        let job1 = try XCTUnwrap(env.doneHeavyJob(model))

        // Arm the finished row at .balanced and let the engine come back no-gain, so the row is
        // recorded FUTILE at .balanced (R6) without touching the shipped version at all — `rowPreset`
        // reads `shipped?.preset` first (R14), so it stays .smallestSize throughout.
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.versions(for: job1)?.rowPreset, .smallestSize)
        env.stub.script = nil

        // A second file joins the list alongside the finished row, and the batch runs at .balanced
        // too — the SAME preset the row is now futile at. Being futile, the row does not arm (R6),
        // so it takes no part in this run's engine calls and `ToolQueue` never touches it: this is
        // the adversarial batch-time case — a later batch running at a preset that differs from the
        // finished row's own, while that row sits out the run untouched. Recording a pending preset
        // for it anyway (the §9.5 defect) would let the row's finished record get silently rewritten
        // to .balanced on the next ingest, even though nothing recompressed it.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        XCTAssertEqual(model.versions(for: job1)?.rowPreset, .smallestSize,
                       "a later batch that didn't recompress this row must not rewrite its preset")

        // The first row's runner-up vanishes, so switching it honestly re-runs the job — which
        // must go through the engine at the preset that row was compressed at.
        let job = try XCTUnwrap(model.jobs.first { $0.url == env.input })
        try FileManager.default.removeItem(at: try XCTUnwrap(job.alternateURL))
        let callsBefore = env.stub.callCount

        await model.useVersion(.runnerUp, for: job)
        try await waitUntil(timeout: 5) {
            env.stub.callCount > callsBefore && !model.switchesInFlight.contains(job.id)
        }

        XCTAssertEqual(env.stub.presets.last, .smallestSize,
                       "the re-run must reproduce the row's own output, not the current preset")
    }

    /// The delivered file can disappear behind the app's back (deleted or moved in Finder — there
    /// is no file watcher). The switch must then fail loudly: re-running would regenerate the pair
    /// around a stale runner-up, and two further switches would hand the user the HEAVY file under
    /// the "Normal compression" label with gs's byte count in the row and the batch totals.
    func testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        await model.useVersion(.runnerUp, for: job)                       // now shipping the normal version
        job = try XCTUnwrap(env.doneHeavyJob(model))
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes)

        try FileManager.default.removeItem(at: shippedURL)  // the user deletes it in Finder
        let callsBefore = env.stub.callCount

        await model.useVersion(.runnerUp, for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore,
                       "a row whose delivered file is gone must not be re-run behind the user's back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shippedURL.path),
                       "the deleted file must not be silently re-created")
        let row = try XCTUnwrap(model.jobs.first)
        guard case .failed(let message) = row.state else {
            return XCTFail("expected the row to report the failed switch, got \(row.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.versions(for: row),
                     "the row must stop advertising a version pair it cannot back")
        XCTAssertNil(model.displayedSizes(for: row),
                     "and must stop contributing bytes to the batch totals")
    }

    /// Removing a row discards its cached runner-up (R15).
    func testRemoveRowDiscardsRunnerUp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path))

        model.remove(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUpURL.path),
                       "remove must discard the runner-up")
    }

    /// Clearing finished rows discards every runner-up they held (R15).
    func testClearFinishedDiscardsRunnerUps() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let runnerUpURL = try XCTUnwrap(env.doneHeavyJob(model)?.alternateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path))

        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUpURL.path),
                       "clearFinished must discard runner-ups")
    }

    /// Cancelling the batch reclaims a runner-up that a job wrote before the cancel landed (R15).
    func testCancelDiscardsRunnerUpReservations() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        // Hold the job open after it has written both files, so cancel meets a real reservation.
        let gate = Gate()
        env.stub.gate = gate
        model.compress()

        // Wait until the runner-up file exists on disk (the stub writes it before suspending).
        let root = env.storeRoot
        try await waitUntil(timeout: 5) {
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .contains { $0.lastPathComponent.contains("runner-up") } ?? false
        }

        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let leftovers = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.contains("runner-up") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancel must discard the batch's runner-up reservations")
    }

    // MARK: arming (R1/R3/R6/R7)

    /// Selecting a different preset with finished rows showing arms them; the row's own preset
    /// leaves it alone (R1).
    func testSelectingADifferentPresetArmsAFinishedRow() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .none,
                       "the row's own preset must not arm it")

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))
        XCTAssertEqual(model.armedCount, 1)
    }

    /// R3: re-selecting the row's preset disarms it instantly, leaving no residue.
    func testReselectingTheRowsPresetDisarmsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 1)
        model.preset = .balanced
        XCTAssertEqual(model.armedCount, 0)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none)
    }

    /// A `.failed` row never arms — its recourse is re-adding the file, not a re-run (R1).
    func testFailedRowsNeverArm() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.throwOnCall = 1
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        guard case .failed = job.state else { return XCTFail("expected a failed row, got \(job.state)") }
        XCTAssertEqual(model.recompressState(for: job), .none)
        XCTAssertEqual(model.armedCount, 0)
    }

    /// A no-gain row arms at a DIFFERENT preset ("still too big" is exactly its user) but reports
    /// its own preset as futile rather than re-arming a known-futile run (R1/R6).
    func testNoGainRowArmsElsewhereAndIsFutileAtItsOwnPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .futile(.balanced))

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize), "a no-gain row is the 'still too big' case — it arms")
    }

    /// Nothing arms while a run is in flight — the selector is disabled for the duration (R9), and
    /// the state must agree with the control.
    func testNothingArmsWhileARunIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        let gate = Gate()
        env.stub.gate = gate
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 0)
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }
    }

    /// R6's futile record is keyed by `(row, effective preset, verb set)`, and the PRESET term is
    /// the row's own — the half the redesign moved and the half nothing covered. F4's
    /// `QueueAdmissionTests.testFutilityKeyIncludesVerbSet` varies the verb set;
    /// `testNoGainRowArmsElsewhereAndIsFutileAtItsOwnPreset` above varies the BATCH preset. Neither
    /// drives the row back onto a futile preset by override, which is the case that discriminates:
    /// a lookup still reading the batch preset would find no record at Smallest Size and offer to
    /// re-run a job it has already been told cannot shrink — R6's whole point.
    func testFutilityIsKeyedByTheRowsEffectivePresetNotTheBatchs() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        let id = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced), "the record is made at the preset the row ran at")

        // The batch moves away, so the row re-opens at the new preset — the positive control.
        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))

        // …and an override pointing the ROW back at Balanced must find the record again, while the
        // batch still sits at Smallest Size.
        model.setOverride(RowOverride(preset: .balanced), for: id)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced),
                       "futility follows the preset the row would actually run at")
        XCTAssertEqual(model.armedCount, 0, "and a futile row is not in the armed set")

        // Dropping the override hands the row back to the batch, proving the effective preset — not
        // some sticky per-row copy of it — is what the lookup reads.
        model.setOverride(nil, for: id)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))
    }

    // MARK: recompress prediction (R16)

    /// A row whose engine path repeats scales the raw estimate by what the engine actually did —
    /// the calibration that stops an MRC row's recompression being predicted as a 4× growth.
    func testPredictionScalesByTheObservedRatioWhenThePathRepeats() async throws {
        // `.scanColour` at `.smallestSize` is the only pair reachable from this row's `.balanced`
        // shipped preset giving
        // `targetWantsMRC == shippedWasMRC == true` with a non-degenerate ratio: `HeavyEnv` always
        // ships `.compressedHeavy` (`shippedWasMRC` is always true), so the repeating-path case
        // needs a target that is ALSO MRC-eligible — `.scanColour` + a non-Maximum preset — not
        // `.bornDigital`, which is never MRC-eligible and so never repeats the path.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let balanced = try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes)
        let smallest = try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes)
        // Associated EXACTLY as the implementation associates it: `Int(_:)` truncates, so a
        // differently-bracketed expression of the same real number can land one byte away.
        let expected = Int((Double(HeavyEnv.heavyBytes) / Double(balanced)) * Double(smallest))

        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        XCTAssertEqual(predicted, expected,
                       "a scanColour row shipped MRC and staying MRC-eligible at Smallest Size has "
                       + "a path that repeats, so the observed ratio applies")
    }

    /// A `.scanColour` row that shipped MRC crossing to Maximum quality (never MRC-eligible) must
    /// use the RAW estimate — the ratio was learned on a path that will not run.
    func testPredictionUsesTheRawEstimateWhenTheEnginePathChanges() async throws {
        // A large original, so the "must beat the original" guard cannot mask the calibration rule
        // this test exists to pin.
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let raw = try XCTUnwrap(analysis.estimates[.maximumQuality]?.predictedBytes)

        XCTAssertEqual(model.recompressPrediction(for: job, at: .maximumQuality), raw,
                       "an MRC-shipped row crossing to Maximum quality gets the raw gs estimate")
    }

    /// Any prediction at or above the original renders as "may not shrink", never a confident
    /// number (R16) — the model says so by returning nil.
    func testPredictionIsWithheldWhenItWouldNotBeatTheOriginal() async throws {
        // This row takes the RAW-estimate branch, not the scaled one: the shipped version is MRC
        // (`HeavyEnv` produces `.compressedHeavy`) while `.bornDigital` + `.maximumQuality` gives
        // `targetWantsMRC == false`, so the paths differ and no calibration is applied. The guard
        // then fires deterministically because the raw estimate is derived from the REAL fixture,
        // which is far larger than the 1 kB original the stub reports — so `predicted` cannot be
        // below `row.originalBytes` whatever the estimator predicts.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
    }

    /// R10's ARMING half: the missing-original guard fires before a confident number is offered,
    /// not only before the run. A row whose input has been deleted must not display a pill
    /// promising a size the app has no way to produce.
    func testPredictionIsWithheldWhenTheOriginalIsGone() async throws {
        // `.scanColour`, so the POSITIVE control is genuinely confident before the deletion. The
        // shipped version is MRC and `.scanColour` + `.smallestSize` gives `targetWantsMRC == true`,
        // so `targetWantsMRC == shippedWasMRC` and the calibration branch runs: the prediction
        // tracks the shipped 1.2 kB (scaled by raw/baseline), comfortably under the 9 kB original.
        // With `.bornDigital` the paths would differ, the RAW estimate would be used, and that is
        // derived from the multi-megabyte `imagePDF` fixture — the "must beat the original" guard
        // would return nil before the deletion too, and the test would assert nothing.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressPrediction(for: job, at: .smallestSize),
                        "the row predicts confidently while its input is still there")

        try FileManager.default.removeItem(at: env.input)
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize),
                     "no input, no prediction — R10 applies at arming time, not just at run time")
        XCTAssertTrue(model.isOriginalMissing(for: job))
    }

    /// The third term of R16's path test. The calibration gate is the engine's own `wantsMRC`
    /// conjunction — the row's `rebuildScan`, `.scanColour`, and a preset other than Maximum
    /// quality — and the redesign ADDED the first of those (spec §7's per-file settings). The two
    /// path tests above predate it and both move the PRESET term, so an implementation that read
    /// the batch's rebuild decision, or none at all, would pass every one of them while quoting a
    /// scan-rebuild's ratio to a row that has just been told not to rebuild — the over-promise the
    /// calibration exists to remove.
    func testPredictionTakesTheRawEstimateWhenTheRowsRebuildIsOptedOut() async throws {
        // A large original for the reason `testPredictionUsesTheRawEstimateWhenTheEnginePathChanges`
        // needs one: the "must beat the original" guard is checked LAST and would return nil for
        // both legs, testing nothing. `timeBudget` is raised because this asserts on a real
        // analysis — a fallback estimate arrives once and no waiting recovers it.
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour, timeBudget: 5)
        let model = env.model
        model.preset = .balanced
        let id = try await env.runToDone().id
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        // Positive control: rebuild on, `.scanColour`, Smallest Size, shipped MRC — all three terms
        // agree, so the observed ratio is applied and the answer is NOT the raw estimate.
        var job = try XCTUnwrap(model.jobs.first)
        let rawBefore = try XCTUnwrap(model.analysis(for: job)?
            .estimates[.smallestSize]?.predictedBytes)
        let calibrated = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        XCTAssertNotEqual(calibrated, rawBefore,
                          "precondition: with the rebuild on, this row calibrates")

        // The row opts out. That re-prices the analysis onto the gs-only path (spec §6.7), so the
        // raw figure the prediction must now equal is a NEW number — read it after the re-price
        // lands, or this compares against the rebuild's own estimate.
        let displayed = try XCTUnwrap(model.jobs.first?.estimate?.predictedBytes)
        model.setOverride(RowOverride(rebuildScan: false), for: id)
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate?.predictedBytes != displayed }

        job = try XCTUnwrap(model.jobs.first)
        let raw = try XCTUnwrap(model.analysis(for: job)?.estimates[.smallestSize]?.predictedBytes)
        XCTAssertEqual(model.recompressPrediction(for: job, at: .smallestSize), raw,
                       "an MRC-shipped row whose rebuild is off changes path — the ratio learned "
                       + "on the rebuild does not transfer, so the raw estimate stands")

        // Named negative control: the figure an implementation blind to the override would give.
        // Associated exactly as the implementation associates it, and three orders of magnitude
        // away from the right answer, so this test can never pass by accident.
        let baseline = try XCTUnwrap(model.analysis(for: job)?.estimates[.balanced]?.predictedBytes)
        XCTAssertNotEqual(model.recompressPrediction(for: job, at: .smallestSize),
                          Int((Double(HeavyEnv.heavyBytes) / Double(baseline)) * Double(raw)),
                          "quoting the rebuild's own ratio here is the defect this pins")
    }

    // MARK: recompress commit protocol (R10–R13)

    /// The happy path: the fresh result takes the row's existing output path, the version it
    /// replaced is parked as the previous version, and every aggregate follows the new one.
    func testRecompressCommitsAndParksThePreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(row.shipped?.url, shippedURL, "a recompress writes to the row's own output")
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(try fileSize(shippedURL), 700, "the delivered file holds the new version")
        let previous = try XCTUnwrap(row.previous)
        XCTAssertEqual(previous.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(previous.preset, .balanced)
        XCTAssertEqual(try fileSize(previous.url), HeavyEnv.heavyBytes,
                       "the version the user had is parked intact")
        XCTAssertEqual(model.displayedSizes(for: job)?.after, 700)
    }

    /// The shipped file can be deleted outside the app between shipping and the next recompress —
    /// there is nothing to park, but the recompress itself still succeeds, so it must deliver the
    /// fresh result rather than discard it behind a lying "kept your X version" message.
    func testRecompressDeliversTheFreshResultWhenTheShippedFileWasDeletedOutsideTheApp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)
        try FileManager.default.removeItem(at: shippedURL)  // the user deletes it in Finder

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertNil(model.recompressErrors[job.id], "the recompress succeeded — there is no failure to report")
        XCTAssertEqual(row.shipped?.url, shippedURL, "the fresh result lands at the row's own output path")
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(try fileSize(shippedURL), 700, "the new file is actually delivered on disk")
        XCTAssertNil(row.previous, "there was nothing to park")
    }

    /// R7: when the parked previous version was made at the selected preset, the row offers an
    /// instant switch instead of arming a recompute of a file already in the cache.
    ///
    /// Written here rather than in Task 7 (where it was specified): it cannot be satisfied before
    /// the recompress commit exists, because nothing else ever fills the `previous` slot.
    func testPreviousVersionsPresetOffersAnInstantSwitchRatherThanArming() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // Recompress at Smallest, parking the Balanced version.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .instantSwitch(.balanced))
        XCTAssertEqual(model.armedCount, 0)
    }

    /// The Change quality sheet's footer CTA (regression fix, spec §7): an `.instantSwitch` row
    /// pressed through the sheet must actually land the parked previous version on the delivery
    /// path — the SAME on-disk switch `useVersion` drives for the versions popover — not silently
    /// do nothing because the row was in neither `armedJobs` nor a queued state.
    func testConfirmLandsTheParkedVersionForAnInstantSwitchRow() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // Recompress at Smallest, parking the Balanced version.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .instantSwitch(.balanced))
        let shippedURL = try XCTUnwrap(model.versions(for: job)?.shipped?.url)

        await ChangeQualitySheet.confirm(rows: [job], model: model, fallback: .balanced, fallbackExclusions: [])

        let row = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))
        XCTAssertEqual(row.shipped?.preset, .balanced, "the switch, not a recompute, must have landed")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the parked Balanced bytes are back on the delivered path")
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none,
                       "the row now matches its own target — nothing left to switch or arm")
    }

    /// Regression (review finding, spec §7): a press that lands NEITHER an instant switch nor a
    /// `compress()` run — because `canStart` refuses (here: the updater reports busy) and there is
    /// nothing to switch — must not leave the previewed batch preset stuck. The sheet's `isEnabled`
    /// gate (`canSwitch`) only checks row states, so this refusal is invisible to the button.
    func testConfirmRestoresTheFallbackPresetWhenNothingActuallyStarts() async throws {
        final class Flag { var busy = false }
        let flag = Flag()
        let env = try HeavyEnv(isUpdating: { flag.busy })
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .none, "already at its own preset — no work to do")
        flag.busy = true
        XCTAssertFalse(model.canStart, "the updater being busy must refuse the start")

        model.preset = .smallestSize  // the sheet's live preview
        await ChangeQualitySheet.confirm(rows: [job], model: model, fallback: .balanced, fallbackExclusions: [])

        XCTAssertEqual(model.preset, .balanced,
                       "nothing started — the previewed preset must not stick")
    }

    /// Mixed batch (spec §7): an instant-switch row and an armed row pressed through the same
    /// sheet confirm both land — the switch via `useVersion`, the recompress via `compress()` —
    /// while a row that already matches its target is left exactly alone.
    func testConfirmHandlesAMixedBatchOfInstantSwitchArmedAndUnchangedRows() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let instantID = try XCTUnwrap(model.jobs.first).id

        let unchangedID = try await env.addRow()
        let armedID = try await env.addRow()
        model.compress()  // both queued rows land at .balanced, same as the instant-switch row
        try await waitUntil(timeout: 5) { !model.isRunning }
        let unchangedShippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(
            model.jobs.first { $0.id == unchangedID }))?.shipped?.url)
        // Pinned to a preset the batch never moves to below, so it stays armed against ITS OWN
        // target throughout, regardless of what `model.preset` does (R1's row-preset rule).
        model.setOverride(RowOverride(preset: .maximumQuality), for: armedID)

        // Park the instant-switch row's Balanced version behind a Smallest recompress — the
        // other two rows are excluded so this step leaves them exactly as they are.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.setArmedExclusion(true, for: unchangedID)
        model.setArmedExclusion(true, for: armedID)
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.setArmedExclusion(false, for: unchangedID)
        model.setArmedExclusion(false, for: armedID)
        model.preset = .balanced

        let instantJob = try XCTUnwrap(model.jobs.first { $0.id == instantID })
        let unchangedJob = try XCTUnwrap(model.jobs.first { $0.id == unchangedID })
        let armedJob = try XCTUnwrap(model.jobs.first { $0.id == armedID })
        XCTAssertEqual(model.recompressState(for: instantJob), .instantSwitch(.balanced))
        XCTAssertEqual(model.recompressState(for: unchangedJob), .none)
        XCTAssertEqual(model.recompressState(for: armedJob), .armed(.maximumQuality))

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 900),
                                          shippedBytes: 900, runnerUpBytes: nil) }
        await ChangeQualitySheet.confirm(rows: [instantJob, unchangedJob, armedJob], model: model,
                                         fallback: .balanced, fallbackExclusions: [])
        try await waitUntil(timeout: 5) { !model.isRunning }

        let switchedRow = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first { $0.id == instantID })))
        XCTAssertEqual(switchedRow.shipped?.preset, .balanced, "the parked version landed via the switch")

        let recompressedRow = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first { $0.id == armedID })))
        XCTAssertEqual(recompressedRow.shipped?.preset, .maximumQuality, "the armed row was recompressed")

        XCTAssertEqual(try fileSize(unchangedShippedURL), HeavyEnv.heavyBytes,
                       "a row that already matches its target is left exactly alone")
    }

    /// Regression (review finding, R12): `confirm`'s instant-switch loop can record a failure note
    /// on a row whose switch failed for a transient reason that leaves the ROW STATE unchanged
    /// (store contract: any ordinary throw restores the shipped file, so `recompressState` still
    /// reads `.instantSwitch` afterwards — never `.armed`, never queued). `confirm` unconditionally
    /// calls `compress()` right after in the same press whenever `canStart` allows it (its own
    /// doc: a case the button's `isEnabled` does not rule out) — and `compress()` used to blank
    /// `recompressErrors` wholesale at the start of every run, wiping that note before the user
    /// ever saw it, even though this row never actually entered the run it just started.
    func testConfirmPreservesAFailedInstantSwitchNoteAcrossTheSamePresssCompress() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // Park the Balanced version behind a Smallest recompress, so the row reads as an
        // instant-switch candidate back at Balanced.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.preset = .balanced
        let instantJob = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: instantJob), .instantSwitch(.balanced))

        // `compress()` refuses outright (`canStart`) unless something is queued or armed, so a
        // second, unrelated row is needed for the press to actually start a run at all —
        // `confirm`'s own doc names this exact shape ("a case this button's `isEnabled` does not
        // rule out"). Run it to done, then override its target so it reads `.armed`.
        let armedID = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.setOverride(RowOverride(preset: .maximumQuality), for: armedID)
        let armedJob = try XCTUnwrap(model.jobs.first { $0.id == armedID })
        XCTAssertEqual(model.recompressState(for: armedJob), .armed(.maximumQuality))

        // Same asymmetric ACL lever `testAFailedSwitchKeepsAPreviousVersionThatIsStillOnDisk`
        // uses: denying new entries in the OUTPUT folder makes parking the shipped file throw
        // while the parked (previous) file, living in the cache root, is never touched — so the
        // row's `versionStore` record, and hence `recompressState`, is unchanged by the failure.
        let outputFolder = try XCTUnwrap(model.outputFolder)
        try Fixtures.denyingNewEntries(true, at: outputFolder)

        await ChangeQualitySheet.confirm(rows: [instantJob, armedJob], model: model,
                                         fallback: .balanced, fallbackExclusions: [])

        // `recompressState` reads `.none` for every row while `isRunning` (arming is suppressed
        // for the run's duration, R9) — the load-bearing check here is `recompressErrors` itself,
        // not the derived arming state.
        XCTAssertEqual(model.recompressErrors[instantJob.id],
                       "Switch failed — kept your \(CompressPreset.smallestSize.title) version. "
                       + "Try again.",
                       "the failed switch's note must survive the SAME press's compress() call")

        // Let the armed row's own recompress (which the same press just started) actually land,
        // so teardown isn't left with a run in flight.
        try Fixtures.denyingNewEntries(false, at: outputFolder)
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.recompressErrors[instantJob.id],
                       "Switch failed — kept your \(CompressPreset.smallestSize.title) version. "
                       + "Try again.",
                       "and survive to the run's end too")
    }

    /// Regression (spec-fidelity r4/r5): `setArmedExclusions` is the sheet's whole-set restore
    /// rule, exercised by `ChangeQualitySheet`'s `onDisappear` on every non-confirmed exit
    /// (Cancel, Escape, the window closing) — the named acceptance test for that finding:
    /// `armedExclusions` returns to its pre-sheet value after a dismissal with `confirmed == false`.
    func testArmedExclusionsRestoreMirrorsTheSheetsNonConfirmedExit() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()
        let job = try XCTUnwrap(model.jobs.first)

        let initialExclusions = model.armedExclusions
        model.setArmedExclusion(true, for: job.id)
        XCTAssertNotEqual(model.armedExclusions, initialExclusions, "the preview must actually move")

        // Mirrors `ChangeQualitySheet.body`'s `.onDisappear { if !confirmed { … } }`.
        model.setArmedExclusions(initialExclusions)
        XCTAssertEqual(model.armedExclusions, initialExclusions,
                       "armedExclusions returns to its pre-sheet value after a dismissal "
                       + "with confirmed == false")
    }

    /// Regression (r5, sibling of the `started` fix): a press where every instant switch FAILS
    /// and `compress()` is refused must restore both halves of the preview — the previewed
    /// preset AND the previewed exclusion set — exactly like the plain "nothing to do" no-op
    /// case, while leaving the failure note visible so the user knows why.
    func testConfirmRestoresPresetAndExclusionsWhenEveryInstantSwitchFails() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // Park the Balanced version behind a Smallest recompress, so the row reads as an
        // instant-switch candidate back at Balanced.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .instantSwitch(.balanced))

        // Same asymmetric ACL lever the sibling note-preservation test uses: denying new entries
        // in the OUTPUT folder makes parking the shipped file throw while the parked (previous)
        // file is never touched, so the switch fails without moving the row's own state.
        let outputFolder = try XCTUnwrap(model.outputFolder)
        try Fixtures.denyingNewEntries(true, at: outputFolder)

        // A fabricated ID stands in for the sheet's pre-open snapshot — excluding `job` itself
        // would make `recompressState` read `.none` (armedExclusions is checked there too) and
        // the switch below would never even be attempted. `armedExclusions` is a plain ID set
        // with no existence check, so this is a legitimate way to pin the whole-set restore
        // independently of the switch under test.
        let fallbackExclusions: Set<ToolJob.ID> = [UUID()]  // the sheet's snapshot at open
        model.setArmedExclusions([UUID()])                 // the sheet's live preview, since changed
        await ChangeQualitySheet.confirm(rows: [job], model: model, fallback: .balanced,
                                         fallbackExclusions: fallbackExclusions)

        XCTAssertNotNil(model.recompressErrors[job.id], "the failed switch's note must be visible")
        XCTAssertEqual(model.preset, .balanced, "nothing landed — the previewed preset must not stick")
        XCTAssertEqual(model.armedExclusions, fallbackExclusions,
                       "nothing landed — the previewed exclusion set must not stick either")

        try Fixtures.denyingNewEntries(false, at: outputFolder)
    }

    /// Regression (review finding, R12): the missing-shipped-file arm of `useVersion` only sets
    /// `switchFailures`, never `recompressErrors` — so a `confirm` that inferred "landed" from
    /// `recompressErrors[job.id] == nil` would misread this failure as a success, consuming the
    /// exclusion set and letting the sheet's preset stick even though nothing switched. Sibling of
    /// `testConfirmRestoresPresetAndExclusionsWhenEveryInstantSwitchFails`, pinned on the OTHER
    /// failure arm the correctness lens flagged as unaudited.
    func testConfirmDoesNotCountAMissingShippedFileAsALandedSwitch() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // Park the Balanced version behind a Smallest recompress, so the row reads as an
        // instant-switch candidate back at Balanced.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .instantSwitch(.balanced))

        // The user deletes the delivered file in Finder — there is no file watcher — so
        // `useVersion` hits its "no version to switch to" arm, which records the failure only in
        // `switchFailures`, never `recompressErrors`.
        let shippedURL = try XCTUnwrap(model.versions(for: job)?.shipped?.url)
        try FileManager.default.removeItem(at: shippedURL)

        let fallbackExclusions: Set<ToolJob.ID> = [UUID()]  // the sheet's snapshot at open
        model.setArmedExclusions([UUID()])                 // the sheet's live preview, since changed
        await ChangeQualitySheet.confirm(rows: [job], model: model, fallback: .balanced,
                                         fallbackExclusions: fallbackExclusions)

        XCTAssertNil(model.recompressErrors[job.id],
                     "this arm never touches recompressErrors — the old nil-inference bug's blind spot")
        XCTAssertEqual(model.preset, .balanced,
                       "nothing landed — the previewed preset must not stick")
        XCTAssertEqual(model.armedExclusions, fallbackExclusions,
                       "nothing landed — the previewed exclusion set must not stick either")
    }

    /// Regression (r5): a press where a switch actually LANDS consumes the whole exclusion set
    /// for that run — not just the row the confirm touched — mirroring the mixed-batch test's
    /// consume rule but pinned on its own so a regression here fails independently of that test.
    func testConfirmConsumesTheWholeExclusionSetWhenASwitchLands() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .instantSwitch(.balanced))

        let excludedID = try await env.addRow()
        model.setArmedExclusion(true, for: excludedID)

        await ChangeQualitySheet.confirm(rows: [job], model: model, fallback: .balanced, fallbackExclusions: [])

        XCTAssertTrue(model.armedExclusions.isEmpty,
                      "a landed switch consumes the exclusion set exactly for this run")
    }

    /// R12: an engine failure keeps the version the user had, on disk and on screen, and says so.
    func testRecompressFailureKeepsThePreviousVersionAndReportsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the user's file must be exactly as it was")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Recompress failed — kept your Balanced version")
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.versions(for: job)?.previous, "a failed commit parks nothing")
        // The failure message and the armed state COEXIST: a failed recompress leaves the row's
        // preset at Balanced while the selector still says Smallest, so the row is armed again —
        // and the message must survive that, or the user is told nothing about what just failed.
        // This is the pair the view's `lead(for:)` has to resolve in the error's favour.
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "a failed attempt does not record a preset, so the row re-arms (R1)")
    }

    /// R12's message survives until the user moves on, and no longer: changing preset is the user
    /// saying "never mind that, what about this?", and the next run clears it as stale.
    func testARecompressErrorClearsWhenThePresetChangesOrTheNextRunStarts() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressErrors[job.id])

        model.preset = .maximumQuality
        XCTAssertNil(model.recompressErrors[job.id],
                     "the user moved on; a message about the Smallest attempt is now stale")

        // The SECOND half of this test's own name: the next run clears it too. Fail the row again
        // (the preset change re-armed it at Maximum quality), then start a fresh run and assert the
        // message is gone — `compress()` clears `recompressErrors` at the START of the run, so it
        // must be absent while that run is still in flight, not merely after it settles.
        env.stub.throwOnCall = env.stub.callCount + 1
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertNotNil(model.recompressErrors[job.id], "the Maximum-quality attempt failed too")

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        // The preset is deliberately LEFT at Maximum quality: a failed recompress records no
        // preset (R1), so the row is still armed at it and a fresh run needs no preset change.
        // Only the run's own clear can green the assertion below — the preset half this test
        // already covered cannot.
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }
        XCTAssertNil(model.recompressErrors[job.id],
                     "the next run clears the previous run's messages at its start")
        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    /// R9 + R12: cancelling during the QUEUE phase must stop the recompress phase before it
    /// starts. `queue.run` returns normally after a cancel, so nothing about the queue's own
    /// unwinding prevents phase 2 — only the run-scoped guard does.
    func testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // A newly queued row to occupy phase 1, and the finished row armed for phase 2.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        // Phase 1's job is in the engine, behind the gate.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must never reach the engine after a cancel in phase 1")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the armed row's delivered file is exactly as it was")
        XCTAssertNil(model.recompressErrors[try XCTUnwrap(model.jobs.first).id],
                     "a cancel is not a failure")
    }

    /// R9: cancelling an IN-FLIGHT recompress leaves the row's previous result and display
    /// untouched.
    ///
    /// The wait is on the stub's call count, deliberately, not on `model.isRunning`: with the
    /// run-scoped cancel guard in place, `isRunning` goes true before phase 2 begins, so a cancel
    /// fired on that signal alone would be caught by the guard and the engine would never be
    /// entered — the test would pass without ever exercising in-flight cancellation. Waiting for
    /// the call means the engine is genuinely suspended at the gate when the cancel lands.
    /// (`testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase` covers the other case.)
    func testCancellingARecompressKeepsThePreviousResult() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        // The armed row is inside the engine, suspended at the gate — see the note above.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.recompressErrors[job.id], "a cancel is not a failure")
    }

    /// R12: a no-gain recompress ships nothing and clears NOTHING — the shipped version, its URL
    /// and its parked versions all survive, and the row remembers the futile preset (R6).
    func testNoGainRecompressKeepsEveryReference() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let before = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))

        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let after = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(after.shipped, before.shipped, "nothing shipped, so nothing changed")
        XCTAssertEqual(after.runnerUp, before.runnerUp)
        XCTAssertNil(after.previous)
        XCTAssertEqual(try fileSize(try XCTUnwrap(after.shipped?.url)), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.recompressState(for: job), .futile(.smallestSize))
    }

    /// R11: the output path is pinned to the row's existing result even when "Save to" changed
    /// since the first run — a recompress replaces a file, it does not deliver a second one.
    func testRecompressWritesToTheRowsExistingResultPathAfterTheFolderChanged() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let elsewhere = env.storeRoot.deletingLastPathComponent()
            .appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        model.outputFolder = elsewhere

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url, shippedURL)
        XCTAssertEqual(try fileSize(shippedURL), 700)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)).isEmpty,
                      "a recompress must not deliver a second file into the new folder")
    }

    /// R11's reservation seeding: the commit makes the row's file transiently absent, so a queued
    /// same-basename job must be kept off that path by the RESERVATION, not by the file happening
    /// to exist when names are allocated. The DECOY is what makes this test discriminate: it
    /// pushes the armed row off the first free name, so with the seeding deleted the second
    /// batch's unfiltered allocation loop re-hands that row's freed name to the armed row and
    /// gives the NEW job exactly the armed row's shipped path.
    func testAQueuedJobNeverClaimsAnArmedRowsResultPath() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let outputFolder = try XCTUnwrap(model.outputFolder)
        // The decoy occupies `image-compressed.pdf`, so the armed row ships at
        // `image-compressed-1.pdf` rather than the first free name.
        let decoy = outputFolder.appendingPathComponent("image-compressed.pdf")
        try Data().write(to: decoy)

        model.preset = .balanced
        try await env.runToDone()
        let armedRowOutput = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // Stand in for the promote window: the row's delivered file is momentarily not on disk —
        // and the decoy goes too, so `image-compressed.pdf` is free again and NOTHING on disk
        // stands between the new job and the armed row's path except the reservation.
        try FileManager.default.removeItem(at: decoy)
        try FileManager.default.removeItem(at: armedRowOutput)

        model.add([try Fixtures.imagePDF()])       // same basename, different folder
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let newRow = try XCTUnwrap(model.jobs.last)
        XCTAssertNotEqual(newRow.resultURL, armedRowOutput,
                          "the armed row's output must be reserved before any name is allocated")
    }

    /// R11's reservation seeding must cover the two PARKED cache slots too, not just the shipped
    /// path. `RunnerUpStore.promote`'s cache-slot step is best-effort (see its doc), so a live
    /// row's runner-up/previous file can be transiently OR permanently absent while the row still
    /// owns that URL — "a missing runner-up is already a designed-for state". The DECOY makes
    /// this test discriminate exactly as the shipped-path test above does: it pushes row A's real
    /// runner-up reservation to `-1`. Once the decoy and A's own file are gone, an unseeded
    /// batch's per-row wasted reservation for A (every batch reserves a runner-up name for every
    /// row, used or not) naturally re-lands on the freed `-0` name, leaving `-1` — A's REAL,
    /// still-live runner-up path — completely unprotected for a same-basename job B to claim and
    /// overwrite next.
    func testAQueuedJobNeverClaimsAnExistingRowsLiveRunnerUpPath() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let decoy = env.storeRoot.appendingPathComponent("image-runner-up.pdf")
        try Data().write(to: decoy)

        model.preset = .balanced
        try await env.runToDone()
        let firstJob = try XCTUnwrap(model.jobs.first)
        let runnerUpURL = try XCTUnwrap(model.versions(for: firstJob)?.runnerUp?.url)
        XCTAssertNotEqual(runnerUpURL, decoy, "the decoy must have pushed the real reservation to -1")

        // Stand in for the file being absent while the row still owns the slot.
        try FileManager.default.removeItem(at: decoy)
        try FileManager.default.removeItem(at: runnerUpURL)

        model.add([try Fixtures.imagePDF()])       // same basename, different folder
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let secondJob = try XCTUnwrap(model.jobs.last)
        let secondRunnerUp = try XCTUnwrap(model.versions(for: secondJob)?.runnerUp?.url)
        XCTAssertNotEqual(secondRunnerUp, runnerUpURL,
                          "a queued job must not claim an existing row's live runner-up path")
    }

    /// R10: a vanished original stops that row before it starts, says so, and leaves its shipped
    /// result and versions intact. The rest of the batch is unaffected.
    func testMissingOriginalReportsPerRowAndLeavesTheResultIntact() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        try FileManager.default.removeItem(at: env.input)
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(env.stub.callCount, callsBefore, "no engine run without an input")
        XCTAssertEqual(model.recompressErrors[job.id], "The original file is no longer where it was")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertNotNil(model.versions(for: job)?.shipped)
    }

    /// Spec §5's version-cap collision (R14/R15), driven end to end. Both parked slots fill at once
    /// the moment a re-run keeps a second variant of its own: the fresh loser takes the runner-up
    /// slot while the version it replaced parks as the previous. `VersionStoreTests`'
    /// `testConsentRetentionPlusPreviousParkStaysWithinCap` proves the store holds that shape;
    /// nothing proved a real recompress PRODUCES it — and both incumbent re-run tests here
    /// (`testRecompressCommitsAndParksThePreviousVersion`,
    /// `testAPlainResultWithAPreviousVersionOffersTheCapsule`) script a re-run that comes back with
    /// no runner-up at all, so the commit's two slot writes have only ever been exercised apart.
    func testARecompressKeepsARetainedRunnerUpWhileParkingThePrevious() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let firstRunnerUp = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?
            .runnerUp?.url)
        XCTAssertNil(model.versions(for: try XCTUnwrap(model.jobs.first))?.previous,
                     "precondition: only one slot is occupied before the re-run")

        env.stub.script = { _, _ in .init(outcome: .compressedHeavy(before: 9000, after: 600,
                                                                    runnerUpBytes: 2_000),
                                          shippedBytes: 600, runnerUpBytes: 2_000) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))
        XCTAssertEqual(row.shipped?.bytes, 600)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(row.runnerUp?.bytes, 2_000, "the runner-up slot holds THIS run's loser")
        XCTAssertEqual(row.previous?.bytes, HeavyEnv.heavyBytes,
                       "and the previous slot the version this run replaced")
        XCTAssertEqual(row.previous?.preset, .balanced)

        // The cap is four ROWS, not four slots: two parked versions, the file in use, and the
        // untouched original referenced in place (spec §5's ruling; the popover lists exactly this).
        XCTAssertEqual(row.cards.map(\.key), [.shipped, .runnerUp, .previous, .originalReference])
        XCTAssertEqual(row.capsuleTitle, "4 versions")

        // Every named version is really on disk — a card advertising a switch to a file that is not
        // there is the mislabel R12 forbids.
        for card in row.cards {
            XCTAssertTrue(FileManager.default.fileExists(atPath: card.version.url.path),
                          "\(card.key) must name a file that exists")
        }
        XCTAssertEqual(try fileSize(try XCTUnwrap(row.runnerUp?.url)), 2_000)
        XCTAssertEqual(try fileSize(try XCTUnwrap(row.previous?.url)), HeavyEnv.heavyBytes)

        // …and the superseded runner-up is NOT still lying around: replacing the slot discards the
        // file it held, or the session cache grows a version nothing can reach (D6/R18).
        XCTAssertNotEqual(row.runnerUp?.url, firstRunnerUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRunnerUp.path),
                       "the version the runner-up slot no longer holds is discarded, not orphaned")
    }

    // MARK: one run, two phases (R5/R9)

    /// R5: newly added files and armed rows form ONE run behind one button. The counts the button
    /// is titled from must see both sets.
    func testMixedRunCountsBothSets() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.armedCount, 0)

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        XCTAssertEqual(model.pendingCount, 1, "only queued: the button reads Compress")
        XCTAssertEqual(model.armedCount, 0)

        model.preset = .smallestSize
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.armedCount, 1, "both sets: the button reads Compress K · Recompress M")
        XCTAssertTrue(model.canStart)
    }

    /// The armed set alone is enough to arm the button — with nothing queued, "Recompress N PDFs"
    /// must still be pressable.
    func testArmedRowsAloneEnableTheButton() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        XCTAssertFalse(model.canStart)

        model.preset = .smallestSize
        XCTAssertTrue(model.canStart)
    }

    /// Risk 2's resolution, asserted: the recompress phase does not start until the queue phase is
    /// done, so the two mechanisms never run at once and the batch width is never doubled.
    func testTheRecompressPhaseWaitsForTheQueuePhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The queued job is suspended in the engine. The armed row must not have started.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must wait for the queue phase to finish")

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
        XCTAssertEqual(env.stub.callCount, callsBefore + 2)
    }

    /// R9's progress bar is scoped to THIS run's rows: a recompress of one row among several
    /// finished ones opens at zero, not at "already mostly done".
    func testRunProgressIsScopedToTheRunsOwnRows() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input, try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        let armed = model.armedCount
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        XCTAssertEqual(model.runTotalCount, armed, "the denominator is this run's rows only")
        XCTAssertEqual(model.runFinishedCount, 0, "nothing in this run has finished yet")
        XCTAssertLessThan(model.runProgress, 1.0)

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    /// `recordTerminalRunRows` exists so a `.failed` queued row still counts toward the bar: a
    /// failure carries no outcome, so the outcome-driven path never sees it and the run would
    /// stall for ever one row short. Asserted mid-run, because the counters are cleared the
    /// moment the batch ends.
    func testAFailedQueuedRowStillCountsTowardTheProgressBar() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let gate = Gate()
        env.stub.gate = gate
        env.stub.throwOnCall = 1
        model.add([env.input, try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()

        // The gate holds only the SECOND call: the stub throws before it reaches `gate.wait()`, so
        // the failing row is the only one that can reach a terminal state here.
        try await waitUntil(timeout: 10) { model.runFinishedCount == 1 }
        XCTAssertNotNil(model.jobs.first { if case .failed = $0.state { return true } else { return false } },
                        "the row the counter moved for is the failed one")
        XCTAssertEqual(model.runTotalCount, 2)
        XCTAssertGreaterThanOrEqual(model.runProgress, 0.5, "the failed row counts, it does not stall")

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    // MARK: armed-state aggregates and cache lifecycle (R4/R17/R18)

    /// R4 hides the success banner and the "Reveal in Finder" / "Compress More" affordances while
    /// anything is armed — all three hang off `allFinished`, which must therefore stop being true.
    func testAllFinishedIsFalseWhileARowIsArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        XCTAssertTrue(model.allFinished)

        model.preset = .smallestSize
        XCTAssertFalse(model.allFinished, "an armed row means the batch is not finished")

        model.preset = .balanced
        XCTAssertTrue(model.allFinished, "disarming restores the finished state exactly")
    }

    /// R18/D6: "Clear finished" discards the cleared rows' parked files — the previous version
    /// included, not just the runner-up.
    func testClearFinishedDiscardsTheParkedPreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let previous = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.previous?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))

        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path),
                       "the parked previous version must go with the row")
    }

    /// R15: the capsule renders on ANY row holding a PARKED version — including a plain (non-heavy)
    /// result that gained a previous version from a recompress. The gate is the parked slots, not
    /// the card count: the popover's always-present Original reference row puts every delivered row
    /// at two cards or more.
    func testAPlainResultWithAPreviousVersionOffersTheCapsule() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        // A Maximum-quality re-run that comes back plain gs — no runner-up at all.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 2_000),
                                          shippedBytes: 2_000, runnerUpBytes: nil) }
        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))
        XCTAssertNil(row.runnerUp, "the re-run shipped plain gs, so there is no runner-up")
        // Current + previous + the Original reference row F5a's commit records (spec §6.4). The
        // capsule's GATE is still the parked slot, not the card count — this row draws one because
        // it holds a `previous`, and a row with no parked version draws none however many cards
        // the popover would list.
        XCTAssertEqual(row.count, 3, "current + previous + the original still draws the capsule")
        XCTAssertEqual(row.capsuleTitle, "3 versions")
    }

    // MARK: the armed banner's arithmetic (R4)

    /// `armedSummary.extraSaving` is the banner's only number and Task 8's prediction feeds it, so
    /// all three of its branches are pinned here — the untestable consumer (`armedDetail`, private
    /// to a `View`) is the argument FOR asserting at the model, not against asserting at all.
    /// Branch 1: a confident armed row moving to a smaller preset contributes a positive extra.
    func testArmedSummarySumsThePredictedExtraSaving() async throws {
        // Task 8's proven confident pair: `.scanColour` shipped MRC at Balanced and armed at
        // Smallest Size keeps `targetWantsMRC == shippedWasMRC == true`, so the calibration branch
        // runs and a confident number exists.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        // The premise, measured rather than assumed: the sign of `extraSaving` is the sign of
        // `balanced - smallest` in the estimator's own figures, because the prediction is the
        // shipped size scaled by that ratio.
        XCTAssertLessThan(try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes),
                          try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes),
                          "the estimator must rate Smallest Size below Balanced for this row")

        // Read the prediction back rather than recomputing it: `Int(_:)` truncates, and a
        // differently bracketed expression of the same real number lands a byte away.
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1)
        XCTAssertEqual(summary.queuedCount, 0)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertGreaterThan(try XCTUnwrap(summary.extraSaving), 0,
                             "the banner reads \u{2248} saves another N")
    }

    /// Branch 2: moving UP in quality predicts a bigger file, so the extra is zero or negative —
    /// the banner must be able to say "files may grow for the extra quality" rather than show a
    /// negative saving. The row is shipped at Smallest Size and armed at Balanced, the same
    /// repeating-path pair in reverse, over a large original so the "must beat the original" guard
    /// cannot suppress the prediction and send this test down the nil branch instead.
    func testArmedSummaryGoesNonPositiveWhenTheArmedPresetIsLessAggressive() async throws {
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .smallestSize
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .balanced),
                                      "the prediction must exist, or this asserts the nil branch")
        XCTAssertGreaterThan(predicted, HeavyEnv.heavyBytes,
                             "Balanced is rated above Smallest Size, so the scaled figure grows")
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary.extraSaving), 0)
    }

    /// Branch 3: no armed row has a confident prediction ⇒ `extraSaving` is nil, so the banner
    /// shows no detail line rather than a fabricated zero. `armedCount` is asserted alongside it,
    /// or "nil because there is no summary at all" would pass for the wrong reason.
    func testArmedSummaryWithholdsTheExtraWhenNoRowPredictsConfidently() async throws {
        // Task 8's proven no-confident-prediction pair: `.bornDigital` is never MRC-eligible while
        // `HeavyEnv` always ships MRC, so the raw multi-megabyte estimate is used and the "must
        // beat the original" guard fires against the 1 kB original.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .maximumQuality
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1, "the row IS armed — the number is what is missing")
        XCTAssertNil(summary.extraSaving)
    }

    /// The banner's arithmetic is per ROW, not per batch (spec §6.1). All three branches above
    /// price their row at the batch preset because none of them overrides anything, so a summary
    /// still summing at `preset` passes every one — while promising a saving for a run the row
    /// will never make. The pill and the banner must describe the same run.
    func testArmedSummaryPricesAnOverriddenRowAtItsOwnPreset() async throws {
        // The 50 MB original keeps BOTH legs confident: at Maximum quality the row changes engine
        // path and takes the raw estimate, which the "must beat the original" guard would refuse
        // against `HeavyEnv`'s default 9 kB — and a nil prediction contributes nothing, so the
        // test would compare two identical sums.
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour, timeBudget: 5)
        let model = env.model
        model.preset = .balanced
        let id = try await env.runToDone().id
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .smallestSize
        var job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize))
        let atSmallest = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        XCTAssertEqual(model.armedSummary?.extraSaving, HeavyEnv.heavyBytes - atSmallest,
                       "with no override the row prices at the batch preset")

        // The row alone moves to Maximum quality. A preset override re-prices nothing (every preset
        // is predicted in one analysis pass), so the numbers below come from the same estimates.
        model.setOverride(RowOverride(preset: .maximumQuality), for: id)
        job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .armed(.maximumQuality),
                       "the row arms at its own preset")
        let atMaximum = try XCTUnwrap(model.recompressPrediction(for: job, at: .maximumQuality))
        XCTAssertNotEqual(atMaximum, atSmallest, "precondition: the two presets price apart")

        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - atMaximum,
                       "the banner sums what the row will actually run, not what the batch selects")
        XCTAssertNotEqual(summary.extraSaving, HeavyEnv.heavyBytes - atSmallest,
                          "quoting the batch preset's figure here is the defect this pins")
    }

    // MARK: the previous version, end to end (R7/R15)

    /// R7's third card: "Use this" on the PREVIOUS version swaps the delivered file back, records
    /// and all. The whole point of parking it is that this costs no engine call, so the engine must
    /// not be entered — and the file on disk must actually change, not just the record describing it.
    func testUsingThePreviousVersionSwapsTheDeliveredFileBack() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        var job = try XCTUnwrap(model.jobs.first)
        var row = try XCTUnwrap(model.versions(for: job))
        let deliveredURL = try XCTUnwrap(row.shipped?.url)
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(row.previous?.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(row.previous?.preset, .balanced)
        XCTAssertEqual(try fileSize(deliveredURL), 700)
        let callsBefore = env.stub.callCount

        await model.useVersion(.previous, for: job)

        job = try XCTUnwrap(model.jobs.first)
        row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(env.stub.callCount, callsBefore, "an instant switch enters no engine")
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.heavyBytes, "the previous version is shipped")
        XCTAssertEqual(row.shipped?.preset, .balanced)
        XCTAssertEqual(row.previous?.bytes, 700, "…and the Smallest result takes the previous slot")
        XCTAssertEqual(row.previous?.preset, .smallestSize)
        XCTAssertEqual(row.shipped?.url, deliveredURL, "the delivered path is stable across a switch")
        // The record is not the proof: the user's own file at that path must now hold the other
        // version's content.
        XCTAssertEqual(try fileSize(deliveredURL), HeavyEnv.heavyBytes)
    }

    /// A vanished PREVIOUS version can never be regenerated (a re-run reproduces the row's own
    /// preset, not the previous one), so it must say so beside the row and drop the slot — while
    /// leaving the perfectly good delivered result exactly where it is.
    func testUsingAVanishedPreviousVersionReportsItAndDropsTheSlot() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let previous = try XCTUnwrap(model.versions(for: job)?.previous?.url)
        try FileManager.default.removeItem(at: previous)
        let callsBefore = env.stub.callCount

        await model.useVersion(.previous, for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore, "a vanished previous is never re-run")
        XCTAssertNil(model.versions(for: job)?.previous, "the slot is dropped, not left dangling")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "That version is no longer available — recompress at "
                       + "\(CompressPreset.balanced.title) to get it back.")
        XCTAssertEqual(model.versions(for: job)?.shipped?.bytes, 700,
                       "a message beside the row, never a failure that hides a good result")
    }

    /// The mirror image of the test above, and the one that matters most: the swap FAILS while the
    /// previous version is still perfectly present on disk. The swap's first step renames the
    /// SHIPPED file inside the output folder and never touches the parked file, so a read-only
    /// output folder throws with nothing missing. Assuming "the parked file raced away" there would
    /// drop the slot — whose discard DELETES the file — and tell the user their kept version is
    /// gone, destroying the one thing D3/R14 promise to keep over a failure they can simply retry.
    func testAFailedSwitchKeepsAPreviousVersionThatIsStillOnDisk() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        var job = try XCTUnwrap(model.jobs.first)
        let previousURL = try XCTUnwrap(model.versions(for: job)?.previous?.url)
        let deliveredURL = try XCTUnwrap(model.versions(for: job)?.shipped?.url)
        let outputFolder = try XCTUnwrap(model.outputFolder)

        // Deny creating entries in the OUTPUT folder — the same asymmetric ACL lever
        // `RunnerUpStoreTests` uses — so parking the shipped file beside itself throws, while the
        // previous version, which lives in the cache root, is untouched.
        try Fixtures.denyingNewEntries(true, at: outputFolder)
        defer { try? Fixtures.denyingNewEntries(false, at: outputFolder) }

        await model.useVersion(.previous, for: job)

        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path),
                      "the parked file was never touched by the failure — it must survive it")
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(row.previous?.url, previousURL,
                       "the record must survive too, or the version is unreachable and then swept")
        XCTAssertEqual(row.shipped?.bytes, 700, "nothing moved: the row still ships the Smallest result")
        XCTAssertEqual(try fileSize(deliveredURL), 700)
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Switch failed — kept your \(CompressPreset.smallestSize.title) version. "
                       + "Try again.",
                       "an honest transient failure, never a claim that the version is gone")

        // Retry once the folder takes new entries again. It must go through — which is also the
        // proof that the failure path released the re-entrancy guard (a retry that no-ops looks
        // identical to one that failed).
        try Fixtures.denyingNewEntries(false, at: outputFolder)
        await model.useVersion(.previous, for: job)

        job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.versions(for: job)?.shipped?.bytes, HeavyEnv.heavyBytes,
                       "the retry must swap for real")
        XCTAssertEqual(try fileSize(deliveredURL), HeavyEnv.heavyBytes)
        XCTAssertNil(model.recompressErrors[job.id], "a successful retry clears the failure note")
    }

    /// The `.runnerUp` half of the same failure: the parked file here is the row's OWN runner-up,
    /// and `rerunForSwitch` opens by deleting it — so if the "parked file raced away" guard above
    /// were missing for this slot, a transient failure would burn a whole engine run over a runner-up
    /// that was never actually gone.
    func testAFailedRunnerUpSwitchKeepsTheRunnerUpThatIsStillOnDisk() async throws {
        let env = try HeavyEnv()
        let model = env.model
        try await env.runToDone()

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(model.versions(for: job)?.runnerUp?.url)
        let outputFolder = try XCTUnwrap(model.outputFolder)
        let callsBefore = env.stub.callCount

        // Same asymmetric ACL lever as the `.previous` test above: denying new entries in the
        // OUTPUT folder makes parking the shipped file throw while the runner-up itself, still
        // sitting untouched wherever the run wrote it, is never touched by the failed attempt.
        try Fixtures.denyingNewEntries(true, at: outputFolder)
        defer { try? Fixtures.denyingNewEntries(false, at: outputFolder) }

        await model.useVersion(.runnerUp, for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore, "a failed swap must not burn an engine run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path),
                      "the runner-up was never touched by the failure — it must survive it")
        XCTAssertEqual(model.versions(for: job)?.runnerUp?.url, runnerUpURL,
                       "the record must survive too, or the version is unreachable and then swept")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Switch failed — kept your \(CompressPreset.balanced.title) version. Try again.",
                       "an honest transient failure, never a claim that the version is gone")
    }

    // MARK: lead derivation (R2/R6/R10/R12)

    /// A no-gain row renders `.unchanged` (no shipped version ⇒ no size cluster) AND arms — the
    /// pair that made the armed pill invisible on exactly the rows R1 names as its user. Both
    /// halves must hold at once, which is what the view's `.unchanged` lead slot exists to draw.
    func testANoGainRowIsBothUnchangedAndArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        // Both halves, or the nil below would also pass for "there is no row at all" — the wrong
        // reason entirely, and one that would hide a broken no-gain ingest.
        XCTAssertNotNil(model.versions(for: job), "the no-gain attempt IS recorded")
        XCTAssertNil(model.versions(for: job)?.shipped,
                     "…and shipped nothing ⇒ the view renders this row `.unchanged`")
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "…and it is armed, so the `.unchanged` cluster must carry a lead")

        // The same row, futile: the neutral pill lives in that same slot.
        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced))
    }

    /// R10 at arming time: an armed row whose original is gone yields no prediction, which is the
    /// signal the view turns into the error lead instead of a confident pill.
    func testAnArmedRowWithAMissingOriginalOffersNoPrediction() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()

        try FileManager.default.removeItem(at: env.input)
        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize))
        XCTAssertTrue(model.isOriginalMissing(for: job))
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize))
    }

    // MARK: helpers

    private func fileSize(_ url: URL) throws -> Int {
        // `FileManager` (not `URL.resourceValues`, which caches the size on the URL object across
        // the in-place swap) so each read reflects the file's current content.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? Int)
    }


}
