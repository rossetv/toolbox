// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import SwiftUI
import XCTest
@testable import Toolbox

/// Track P-A's own tests: `QueueView`'s screen-state derivation, its drop-acceptance seam, the
/// row-open target `QueueRowsView` computes, and the footer's all-OCR-batch copy rule (spec
/// §6.3's forbidden "0 MB saved" string). A SwiftUI body cannot be unit-tested directly, so every
/// assertion here targets a pure function or method the six view files expose internally.
@MainActor
final class QueueViewStateTests: XCTestCase {

    // MARK: screen-state selection

    func testScreenStateEmptyWhenNoJobs() {
        XCTAssertEqual(QueueView.screenState(jobs: [], isRunning: false, inspections: [:]), .empty)
    }

    func testScreenStateReadyBeforeAnythingHasRun() {
        let jobs = [ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf")),
                    ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))]
        XCTAssertEqual(QueueView.screenState(jobs: jobs, isRunning: false, inspections: [:]), .ready)
    }

    /// A locked/missing/unreadable row surfaces INLINE on the Ready screen (spec §6.6) — it does
    /// not, by itself, promote the screen to `.problems`; nothing has run yet.
    func testScreenStateReadyWithAnUnresolvedProblemRowPresent() {
        let problemJob = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let inspections = [problemJob.id: RowInspection(problem: .locked)]
        let healthyJob = ToolJob(url: URL(fileURLWithPath: "/tmp/healthy.pdf"))
        XCTAssertEqual(QueueView.screenState(jobs: [problemJob, healthyJob], isRunning: false,
                                             inspections: inspections), .ready)
    }

    func testScreenStateWorkingWheneverIsRunningRegardlessOfJobStates() {
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        job.state = .running(0.4)
        XCTAssertEqual(QueueView.screenState(jobs: [job], isRunning: true, inspections: [:]), .working)
    }

    func testScreenStateFinishedWhenEveryRowSucceededCleanly() {
        var a = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        a.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        var b = ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))
        b.state = .done(RowOutcome(originalBytes: 10, finalBytes: 10, compress: .noGain(bytes: 10)))
        XCTAssertEqual(QueueView.screenState(jobs: [a, b], isRunning: false, inspections: [:]), .finished)
    }

    func testScreenStateProblemsWhenAnyRowFailed() {
        var a = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        a.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        var failed = ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))
        failed.state = .failed("Couldn't be compressed")
        XCTAssertEqual(QueueView.screenState(jobs: [a, failed], isRunning: false, inspections: [:]), .problems)
    }

    /// Screen 10's own shape: a batch has run and left an unresolved problem row behind (never
    /// skipped, never run — it was excluded from the batch entirely) alongside rows that
    /// finished. `allFinished` would read this as "not finished" forever (the problem row never
    /// reaches a terminal state) — this derivation reads the jobs directly instead.
    func testScreenStateProblemsWhenAnUnresolvedProblemRowOutlivesTheRun() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let stuck = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let inspections = [stuck.id: RowInspection(problem: .locked)]
        XCTAssertEqual(QueueView.screenState(jobs: [done, stuck], isRunning: false, inspections: inspections), .problems)
    }

    /// A skipped problem row is resolved-by-skip (screenState's own doc comment) — it must NOT
    /// pin the screen on `.problems` forever alongside otherwise-finished rows.
    func testScreenStateFinishedWhenOnlyUnresolvedRowWasSkipped() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let skipped = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let inspections = [skipped.id: RowInspection(problem: .locked)]
        XCTAssertEqual(QueueView.screenState(jobs: [done, skipped], isRunning: false,
                                             inspections: inspections, skipped: [skipped.id]), .finished)
    }

    /// Add More on a finished batch (spec §7): a clean `.queued` row (no problem, not skipped)
    /// alongside terminal rows must pull the screen back to `.ready` — the strand this finding
    /// fixed — with `canStart` agreeing there is runnable work, never `.ready` with Start refused.
    func testScreenStateReadyWhenACleanQueuedRowJoinsAFinishedBatch() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let added = ToolJob(url: URL(fileURLWithPath: "/tmp/added.pdf"))
        XCTAssertEqual(QueueView.screenState(jobs: [done, added], isRunning: false, inspections: [:]), .ready)
    }

    /// End-to-end: the exact repro (finished batch → Add More) through the real pipeline. The
    /// screen must return to `.ready` and `canStart` must agree the new row is runnable.
    func testAddMoreOnAFinishedBatchReturnsToReadyAndCanStartRunsIt() async throws {
        let env = try HeavyEnv()
        _ = try await env.runToDone()
        XCTAssertEqual(QueueView.screenState(jobs: env.model.jobs, isRunning: env.model.isRunning,
                                             inspections: env.model.inspections,
                                             skipped: env.model.skippedRows), .finished,
                       "sanity: the batch really is finished before Add More")

        try await env.addRow(Fixtures.textImagePDF())

        XCTAssertEqual(QueueView.screenState(jobs: env.model.jobs, isRunning: env.model.isRunning,
                                             inspections: env.model.inspections,
                                             skipped: env.model.skippedRows), .ready,
                       "the added clean row must pull the screen back to .ready, never stranding it")
        XCTAssertTrue(env.model.canStart, "the added clean row must be startable, not stranded")
    }

    /// The sibling behaviour landed this round (8753c76) must survive: a skipped problem row
    /// alone, with nothing else queued, must NOT flip a finished batch back to `.ready`/`.problems`.
    func testScreenStateFinishedWhenOnlyRowBesideTerminalIsASkippedProblem() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let skipped = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let inspections = [skipped.id: RowInspection(problem: .locked)]
        XCTAssertEqual(QueueView.screenState(jobs: [done, skipped], isRunning: false,
                                             inspections: inspections, skipped: [skipped.id]), .finished)
    }

    /// A clean pending row alongside an unresolved problem row must still report `.problems` — a
    /// clean row never launders away a genuine unresolved problem left behind by the batch.
    func testScreenStateProblemsWhenACleanPendingRowJoinsAnUnresolvedProblemRow() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let stuck = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let added = ToolJob(url: URL(fileURLWithPath: "/tmp/added.pdf"))
        let inspections = [stuck.id: RowInspection(problem: .locked)]
        XCTAssertEqual(QueueView.screenState(jobs: [done, stuck, added], isRunning: false,
                                             inspections: inspections), .problems)
    }

    /// Likewise a clean pending row must not launder away a failed row.
    func testScreenStateProblemsWhenACleanPendingRowJoinsAFailedRow() {
        var failed = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        failed.state = .failed("Couldn't be compressed")
        let added = ToolJob(url: URL(fileURLWithPath: "/tmp/added.pdf"))
        XCTAssertEqual(QueueView.screenState(jobs: [failed, added], isRunning: false, inspections: [:]), .problems)
    }

    /// Finding B/A repro: a skipped `.failed` row is resolved-by-skip, same as a skipped problem
    /// row — it must not pin the screen on `.problems` by itself.
    func testScreenStateFinishedWhenOnlyFailedRowWasSkipped() {
        var done = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        done.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        var skippedFailed = ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))
        skippedFailed.state = .failed("Couldn't be compressed")
        XCTAssertEqual(QueueView.screenState(jobs: [done, skippedFailed], isRunning: false,
                                             inspections: [:], skipped: [skippedFailed.id]), .finished)
    }

    /// Finding A's exact repro: Add More on a batch carrying a failed row must not strand the new
    /// clean row — it must pull the screen back to `.ready` (mixed failed+pending rows on screen
    /// 03) so Start is reachable, never leaving it on `.problems` where the footer has no Start.
    func testScreenStateReadyWhenACleanPendingRowJoinsAFailedRowThatWasSkipped() {
        var skippedFailed = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        skippedFailed.state = .failed("Couldn't be compressed")
        let added = ToolJob(url: URL(fileURLWithPath: "/tmp/added.pdf"))
        XCTAssertEqual(QueueView.screenState(jobs: [skippedFailed, added], isRunning: false,
                                             inspections: [:], skipped: [skippedFailed.id]), .ready)
    }

    /// The other half of the two tests above: an unresolved failure correctly PINS the screen on
    /// `.problems`, so that footer must itself carry Start — otherwise the clean pending row beside
    /// it has an estimate, `canStart` is true, and no control on screen calls `compress()`. Screen
    /// 10 keeps its own shape when nothing is runnable, and Start never leaks onto screen 06.
    func testProblemsFooterOffersStartWhenCleanWorkRemains() {
        var failed = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        failed.state = .failed("Couldn't be compressed")
        let added = ToolJob(url: URL(fileURLWithPath: "/tmp/added.pdf"))
        let state = QueueView.screenState(jobs: [failed, added], isRunning: false, inspections: [:])
        XCTAssertEqual(state, .problems, "sanity: the unresolved failure still owns the screen")

        XCTAssertTrue(QueueFooterView.showsStart(state: state, canStart: true),
                      "runnable work on a problems screen must have a Start to press")
        XCTAssertFalse(QueueFooterView.showsStart(state: state, canStart: false),
                       "nothing runnable ⇒ screen 10 renders exactly as designed, no dead control")
        XCTAssertFalse(QueueFooterView.showsStart(state: .finished, canStart: true),
                       "screen 06 offers Add More, never Start")
    }

    // MARK: rows dim while Quality/OCR popover is open (spec §7, DESIGN.md §9 04/04b)

    func testRowsDimOpacityFullWhenNeitherPopoverIsOpen() {
        XCTAssertEqual(QueueView.rowsDimOpacity(qualityOpen: false, ocrOpen: false), 1.0)
    }

    func testRowsDimOpacityDimsToFortyPercentWhileQualityPopoverIsOpen() {
        XCTAssertEqual(QueueView.rowsDimOpacity(qualityOpen: true, ocrOpen: false), 0.4)
    }

    func testRowsDimOpacityDimsToFortyPercentWhileOCRPopoverIsOpen() {
        XCTAssertEqual(QueueView.rowsDimOpacity(qualityOpen: false, ocrOpen: true), 0.4)
    }

    func testRowsDimOpacityDimsWhenBothPopoversAreSomehowOpen() {
        XCTAssertEqual(QueueView.rowsDimOpacity(qualityOpen: true, ocrOpen: true), 0.4)
    }

    // MARK: drop acceptance — the invariant is "never gated on state" (spec §6.5)

    func testAcceptDropAddsWhenIdle() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        let view = makeView(model: model)
        let url = try! Fixtures.imagePDF()
        XCTAssertTrue(view.acceptDrop([url]))
        XCTAssertEqual(model.jobs.count, 1)
    }

    func testAcceptDropAddsDuringALiveRun() async throws {
        let env = try HeavyEnv()
        let gate = Gate()
        env.stub.gate = gate
        let view = makeView(model: env.model)
        _ = try await env.addRow()
        env.model.compress()
        // The first job is inside the engine, suspended — so the batch is genuinely live
        // (mirrors `QueueAdmissionTests.testAddDuringRunJoinsBatch`'s own construction).
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        XCTAssertTrue(env.model.isRunning)

        let secondURL = try Fixtures.textImagePDF()
        XCTAssertTrue(view.acceptDrop([secondURL]),
                      "QueueView.acceptDrop must never gate on isRunning (spec §6.5)")
        XCTAssertEqual(env.model.jobs.count, 2, "a drop mid-run must be admitted")

        await gate.open()
        try await waitUntil(timeout: 15) { !env.model.isRunning }
    }

    // MARK: drop refused while the Choose Files/Choose Folder panel is up (the one modal exception)

    func testShouldAcceptDropRefusesWhileModalWindowPresented() {
        XCTAssertFalse(QueueView.shouldAcceptDrop(modalWindowPresented: true))
    }

    func testShouldAcceptDropAllowsWhenNoModalWindowPresented() {
        XCTAssertTrue(QueueView.shouldAcceptDrop(modalWindowPresented: false))
    }

    func testAcceptDropRefusesAndDoesNotMutateQueueWhileModalWindowPresented() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        let view = makeView(model: model)
        let url = try! Fixtures.imagePDF()
        XCTAssertFalse(view.acceptDrop([url], modalWindowPresented: true),
                       "a drop underneath the Choose Files panel must be refused")
        XCTAssertEqual(model.jobs.count, 0, "the queue must not mutate underneath the modal panel")
    }

    // MARK: row-open target ("Return on a focused row invokes onOpen")

    func testUrlToOpenFallsBackToOriginalWhenNothingHasRunYet() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        let job = ToolJob(url: URL(fileURLWithPath: "/tmp/plain.pdf"))
        XCTAssertEqual(QueueRowsView.urlToOpen(for: job, model: model), job.url)
    }

    func testUrlToOpenPrefersTheStoresShippedVersion() async throws {
        let env = try HeavyEnv()
        let job = try await env.runToDone()
        let shipped = try XCTUnwrap(env.model.versions(for: job)?.shipped?.url)
        XCTAssertEqual(QueueRowsView.urlToOpen(for: job, model: env.model), shipped,
                       "the STORE's shipped file, not job.resultURL, is authoritative")
    }

    // MARK: footer copy — spec §6.3's forbidden string

    func testWorkingFooterNeverSaysZeroMBSaved() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        // No `batchProgress` at all (nothing has run) is the degenerate case of "nothing saved
        // yet" — the headline must still never read "0 MB saved so far".
        let headline = QueueFooterView.workingHeadline(model: model)
        XCTAssertFalse(headline.contains("0 "), "never a bare zero-byte saved figure: \(headline)")
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("0 mb"))
    }

    /// The scenario the plan names directly: an all-OCR batch (noGain compress verdict, OCR
    /// `.added`) delivers `-ocr.pdf` with no shipped-version savings (spec §6.5) — the footer
    /// must read the searchable count, never "0 MB saved". Driven through the REAL pipeline
    /// (`StubCompressEngine`/`StubOCREngine`), mirroring `QueuePassTests`' own
    /// `testNoGainWithOCRDeliversOcrName` construction, rather than a hand-built store row.
    func testAllOCRBatchFooterNeverSaysZeroSaved() async throws {
        let pageText: [Int: [PositionedText]] = [0: [PositionedText(
            text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))]]
        let added = RecognisedDocument(pageText: pageText,
                                       geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
                                       pagesRecognised: 1, pagesSkipped: 0, pageCount: 1)
        let ocr = StubOCREngine(document: added)
        let env = try HeavyEnv(ocrEngine: ocr)
        env.model.ocrOn = true
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        _ = try await env.addRow()
        env.model.compress()
        try await waitUntil(timeout: 15) { !env.model.isRunning }

        XCTAssertNil(env.model.jobs.first.flatMap { env.model.displayedSizes(for: $0) },
                     "an OCR-only delivery makes no before/after claim")
        let headline = QueueFooterView.workingHeadline(model: env.model)
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("0 mb"), "forbidden string: \(headline)")
        XCTAssertEqual(headline, "1 file made searchable so far")
    }

    /// Compress-only rows carry no searchability claim in either direction (spec §6.4's absence
    /// rule) — asserted against a REAL compress-only delivery (`HeavyEnv`'s own MRC pair, OCR
    /// never engaged), never a hand-built stand-in.
    func testCompressOnlyRowHasNoSearchabilitySubtitleEitherWay() async throws {
        let env = try HeavyEnv()
        let job = try await env.runToDone()
        let descriptor = QueueRowsView.describe(job: job, model: env.model, state: .finished)
        XCTAssertFalse(descriptor.meta.localizedCaseInsensitiveContains("searchable"),
                       "a compress-only row must not claim searchable OR not-searchable: \(descriptor.meta)")
    }

    /// DESIGN.md §9 06 / spec §6.5: a no-op (compress-only, no OCR) finished row renders a grey
    /// SIZE PAIR (same figure twice, no arrow) + `StatusIndicator(.unchanged)` — never a single
    /// figure.
    func testCompressOnlyRowRendersGreySizePairNotASingleFigure() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        let outcome = RowOutcome(
            originalBytes: 1000,
            finalBytes: 1000,
            compress: .noGain(bytes: 1000),
            ocr: nil,
            shippedVariant: nil,
            runnerUp: nil
        )
        job.state = .done(outcome)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .finished)
        guard case .sizeColumn(let current, let target, let kind, let sameSize) = descriptor.trailing else {
            return XCTFail("expected .sizeColumn trailing for a no-op finished row, got \(descriptor.trailing)")
        }
        XCTAssertEqual(current, target, "no-op row must show the SAME figure twice, not before/after")
        XCTAssertTrue(sameSize, "no-op row must use the arrowless same-size treatment")
        XCTAssertEqual(kind, .unchanged)
    }

    /// The noGain+OCR-added sibling (spec §6.5): OCR made the file searchable but there's still
    /// no shipped-version savings claim — the row must render the SAME grey size pair keyed on
    /// its actual bytes, not a single figure.
    func testAllOCRRowRendersGreySizePairKeyedOnActualBytes() async throws {
        let pageText: [Int: [PositionedText]] = [0: [PositionedText(
            text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))]]
        let added = RecognisedDocument(pageText: pageText,
                                       geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
                                       pagesRecognised: 1, pagesSkipped: 0, pageCount: 1)
        let ocr = StubOCREngine(document: added)
        let env = try HeavyEnv(ocrEngine: ocr)
        env.model.ocrOn = true
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        _ = try await env.addRow()
        env.model.compress()
        try await waitUntil(timeout: 15) { !env.model.isRunning }
        let job = try XCTUnwrap(env.model.jobs.first)

        let descriptor = QueueRowsView.describe(job: job, model: env.model, state: .finished)
        guard case .sizeColumn(let current, let target, let kind, let sameSize) = descriptor.trailing else {
            return XCTFail("expected .sizeColumn trailing for an OCR-only finished row, got \(descriptor.trailing)")
        }
        XCTAssertEqual(current, target, "OCR-only row must show the SAME figure twice, no savings claim")
        XCTAssertTrue(sameSize, "OCR-only row must use the arrowless same-size treatment")
        XCTAssertEqual(kind, .unchanged)
    }

    // MARK: noGain composite copy (spec §6.5, DESIGN.md §11)

    /// noGain compress with OCR `.tooFaint` renders the spec's pinned composite "Already optimised · too faint to read"
    /// and marks the row degraded — this is the missing partition that describeDegraded now handles.
    func testNoGainWithOCRTooFaintRendersExactComposite() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        let outcome = RowOutcome(
            originalBytes: 1000,
            finalBytes: 1000,
            compress: .noGain(bytes: 1000),
            ocr: .tooFaint,
            shippedVariant: nil,
            runnerUp: nil
        )
        job.state = .done(outcome)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .finished)
        XCTAssertEqual(descriptor.meta, "Already optimised · too faint to read",
                       "noGain+OCR.tooFaint must render the spec's pinned composite (spec §6.5, DESIGN.md §11)")
        XCTAssertEqual(descriptor.emphasis, .degraded, "noGain+tooFaint must be marked degraded")
    }

    // MARK: RowDescriptor.Trailing.sizeColumn coverage (25f29c9's own enum + hand-written ==)

    /// A delivered (compressed) row's before/after pair: distinct `current`/`target` figures,
    /// `kind: .finished`, `sameSize: false` — the arm every other `.sizeColumn` test in this file
    /// deliberately avoids (they all key on the arrowless same-size treatment instead).
    func testDeliveredRowRendersBeforeAfterPairWithFinishedKind() async throws {
        let env = try HeavyEnv()
        let job = try await env.runToDone()
        let descriptor = QueueRowsView.describe(job: job, model: env.model, state: .finished)
        guard case .sizeColumn(let current, let target, let kind, let sameSize) = descriptor.trailing else {
            return XCTFail("expected .sizeColumn trailing for a delivered row, got \(descriptor.trailing)")
        }
        XCTAssertNotEqual(current, target, "a delivered row must show a before/after pair, not the same figure twice")
        XCTAssertEqual(kind, .finished)
        XCTAssertFalse(sameSize)
    }

    /// A queued row on the Ready screen (nothing has run yet — spec §7, screen 03) renders its
    /// input-size/estimate pair with `kind: nil` (no `StatusIndicator` glyph) — the "Next" queued
    /// row on screen 05 is a different branch (`kind: .queued`, tested by
    /// `testRunningRowIsMarkedActive`'s siblings) and must not be confused with this one.
    func testQueuedReadyRowRendersEstimatePairWithNoKind() async throws {
        let env = try HeavyEnv()
        let jobID = try await env.addRow()
        try await waitUntil(timeout: 5) {
            env.model.jobs.first { $0.id == jobID }?.estimate != nil
        }
        let job = try XCTUnwrap(env.model.jobs.first { $0.id == jobID })
        let descriptor = QueueRowsView.describe(job: job, model: env.model, state: .ready)
        guard case .sizeColumn(let current, let target, let kind, let sameSize) = descriptor.trailing else {
            return XCTFail("expected .sizeColumn trailing for a queued Ready row, got \(descriptor.trailing)")
        }
        XCTAssertFalse(current.isEmpty)
        XCTAssertFalse(target.isEmpty)
        XCTAssertNil(kind, "a queued Ready row shows no StatusIndicator glyph")
        XCTAssertFalse(sameSize)
    }

    /// The hand-written `Trailing.==` must distinguish every associated value — a mutation in
    /// any single one (current, target, kind, sameSize) must fail equality, never
    /// pass by comparing only a subset.
    func testSizeColumnEqualityDistinguishesEveryAssociatedValue() {
        let base = QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "1 MB", target: "500 KB", kind: .finished, sameSize: false)

        XCTAssertEqual(base, QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "1 MB", target: "500 KB", kind: .finished, sameSize: false),
            "identical values must compare equal")

        XCTAssertNotEqual(base, QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "2 MB", target: "500 KB", kind: .finished, sameSize: false),
            "current alone must break equality")

        XCTAssertNotEqual(base, QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "1 MB", target: "600 KB", kind: .finished, sameSize: false),
            "target alone must break equality")

        XCTAssertNotEqual(base, QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "1 MB", target: "500 KB", kind: .unchanged, sameSize: false),
            "kind alone must break equality")

        XCTAssertNotEqual(base, QueueRowsView.RowDescriptor.Trailing.sizeColumn(
            current: "1 MB", target: "500 KB", kind: .finished, sameSize: true),
            "sameSize alone must break equality")

        XCTAssertNotEqual(base, QueueRowsView.RowDescriptor.Trailing.status(text: "1 MB", kind: .finished),
                          "a different case entirely must never compare equal")
    }

    /// OCR-only row (Compress chip OFF, so compress=nil) with OCR outcome .tooFaint must render
    /// the honest sibling copy "Too faint to read — not searchable" (spec §6.5), never the lie
    /// "compressed, but not searchable" that applies only when compression actually ran.
    func testOCROnlyWithTooFaintRendersNotCompressedCopy() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        let outcome = RowOutcome(
            originalBytes: 1000,
            finalBytes: 1000,
            compress: nil,  // Compress verb was OFF
            ocr: .tooFaint,
            shippedVariant: nil,
            runnerUp: nil
        )
        job.state = .done(outcome)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .finished)
        XCTAssertEqual(descriptor.meta, "Too faint to read — not searchable",
                       "OCR-only tooFaint must not falsely claim compression (spec §6.5)")
        XCTAssertEqual(descriptor.emphasis, .degraded, "OCR-only tooFaint must be marked degraded")
    }

    // MARK: describeDone reads the STORE, never a stale first-run outcome (binding carry #1)

    /// A change-quality re-run never touches `job.state` (`QueueViewModel.commit()`) — only the
    /// STORE's `shipped.variant` is fresh. A Balanced-MRC row re-run at Maximum quality (a plain
    /// gs file) must render "Compressed", not the stale first run's "Rebuilt".
    func testChangeQualityRerunFromMRCToPlainRendersCompressedNotRebuilt() async throws {
        let pageText: [Int: [PositionedText]] = [0: [PositionedText(
            text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))]]
        let added = RecognisedDocument(pageText: pageText,
                                       geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
                                       pagesRecognised: 1, pagesSkipped: 0, pageCount: 1)
        let env = try HeavyEnv(ocrEngine: StubOCREngine(document: added))
        env.model.ocrOn = true
        let staleJob = try await env.runToDone()
        let firstPass = QueueRowsView.describe(job: staleJob, model: env.model, state: .finished)
        XCTAssertTrue(firstPass.meta.contains("Rebuilt"),
                      "sanity: the first run really did ship the MRC variant: \(firstPass.meta)")

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        env.model.preset = .maximumQuality
        env.model.compress()
        try await waitUntil(timeout: 5) { !env.model.isRunning }
        XCTAssertEqual(env.model.versions(for: staleJob)?.shipped?.variant, .plain,
                       "sanity: the store's shipped card really is the fresh plain gs file")

        // `staleJob` is the frozen struct from before the re-run — its `.state` still carries the
        // first pass's MRC outcome, exactly as `job.state` stays in the real queue.
        let descriptor = QueueRowsView.describe(job: staleJob, model: env.model, state: .finished)
        XCTAssertTrue(descriptor.meta.contains("Compressed"),
                      "the store's fresh plain variant must win over the stale MRC outcome: \(descriptor.meta)")
        XCTAssertFalse(descriptor.meta.contains("Rebuilt"),
                       "must not still read the stale first run's verb: \(descriptor.meta)")
    }

    /// A row cancelled between the legs on its first pass (`ocr == .cancelled`, `isDegraded ==
    /// true`) that is later re-run successfully must stop rendering the permanent "cancelled
    /// before reading" string — the store's confirmed-searchable shipped card is fresher than the
    /// stale first-run outcome baked into `job.state`.
    func testStaleCancelledOutcomeRendersFromStoreAfterASuccessfulRerun() async throws {
        let pageText: [Int: [PositionedText]] = [0: [PositionedText(
            text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))]]
        let added = RecognisedDocument(pageText: pageText,
                                       geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
                                       pagesRecognised: 1, pagesSkipped: 0, pageCount: 1)
        let env = try HeavyEnv(ocrEngine: StubOCREngine(document: added))
        env.model.ocrOn = true
        var staleJob = try await env.runToDone()
        XCTAssertEqual(env.model.versions(for: staleJob)?.searchableByCard[.shipped], true,
                       "sanity: the re-run really did land a confirmed-searchable shipped card")

        // Simulate the stale outcome a re-run leaves behind: the FIRST pass was cancelled before
        // its OCR leg ever read the file (`commit()` never overwrites `job.state`).
        staleJob.state = .done(RowOutcome(
            originalBytes: 9000, finalBytes: HeavyEnv.heavyBytes,
            compress: .compressed(before: 9000, after: HeavyEnv.heavyBytes),
            ocr: .cancelled, shippedVariant: .mrc,
            runnerUp: RetainedVariant(kind: .plain, bytes: HeavyEnv.normalBytes, searchable: false)))

        let descriptor = QueueRowsView.describe(job: staleJob, model: env.model, state: .finished)
        XCTAssertFalse(descriptor.meta.localizedCaseInsensitiveContains("cancelled"),
                       "the store's fresh searchable card must win over the stale cancelled outcome: \(descriptor.meta)")
        XCTAssertNotEqual(descriptor.emphasis, .degraded,
                          "a store-confirmed searchable row must not render permanently degraded")
    }

    /// A running row must be marked `.active` (DESIGN.md §9 05, spec §7): accent-tinted
    /// background, slow shimmer, accent meta — none of which fire without this emphasis wired.
    func testRunningRowIsMarkedActive() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/running.pdf"))
        job.state = .running(0.4)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .working)
        XCTAssertEqual(descriptor.emphasis, .active, "a running row must render the active emphasis")
    }

    // MARK: run-time failure → problem-row copy (spec §6.6's "second net", §7)

    /// A run-time failure that `OpenGuard` would also have caught at add-time (locked/missing/
    /// unreadable) must render the SAME design copy as the add-time path, never the raw engine
    /// string — and a moved file keeps its "Find it…" affordance and warn (not danger) tint.
    func testRunTimeMissingFailureGetsMovedCopyAndFindItAffordance() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/moved.pdf"))
        job.state = .failed(OpenGuardError.fileNotFound.localizedDescription)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .problems)
        XCTAssertEqual(descriptor.meta, "Moved or renamed since you added it")
        XCTAssertEqual(descriptor.emphasis, .problemWarn)
        guard case .problem(let primary, let link) = descriptor.trailing else {
            return XCTFail("expected .problem trailing with a Find it… affordance, got \(descriptor.trailing)")
        }
        XCTAssertEqual(primary?.title, "Find it…")
        XCTAssertEqual(link?.title, "Remove")
    }

    /// Mid-run, `rebind` refuses (spec §7) so "Find it…" would be a silent no-op — the affordance
    /// must be absent while `isRunning`, and reappear once the run ends (fix R3).
    func testRunTimeMissingFailureHidesFindItWhileRunningThenShowsItAfter() async throws {
        let env = try HeavyEnv()
        let gate = Gate()
        env.stub.gate = gate
        _ = try await env.addRow()
        env.model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        XCTAssertTrue(env.model.isRunning)

        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/moved.pdf"))
        job.state = .failed(OpenGuardError.fileNotFound.localizedDescription)
        let runningDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .working)
        guard case .problem(let runningPrimary, let runningLink) = runningDescriptor.trailing else {
            return XCTFail("expected .problem trailing, got \(runningDescriptor.trailing)")
        }
        XCTAssertNil(runningPrimary, "Find it… must not appear mid-run since rebind refuses while isRunning")
        XCTAssertNil(runningLink, "Remove must not appear mid-run since remove(_:) refuses while isRunning")

        await gate.open()
        try await waitUntil(timeout: 15) { !env.model.isRunning }

        let doneDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .problems)
        guard case .problem(let donePrimary, let doneLink) = doneDescriptor.trailing else {
            return XCTFail("expected .problem trailing, got \(doneDescriptor.trailing)")
        }
        XCTAssertEqual(donePrimary?.title, "Find it…", "the affordance must return once the run ends")
        XCTAssertEqual(doneLink?.title, "Remove", "Remove must return once the run ends")
    }

    /// Same rule as "Find it…" above, applied to Skip/Remove on a locked/unreadable problem row:
    /// `setSkipped`/`remove(_:)` both refuse mid-run, so the buttons are absent for the run's
    /// duration and reappear once it ends.
    func testLockedFailureHidesSkipAndRemoveWhileRunningThenShowsThemAfter() async throws {
        let env = try HeavyEnv()
        let gate = Gate()
        env.stub.gate = gate
        _ = try await env.addRow()
        env.model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        XCTAssertTrue(env.model.isRunning)

        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        job.state = .failed(CompressError.encrypted.localizedDescription)
        let runningDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .working)
        guard case .problemPair(let runningSkip, let runningRemove) = runningDescriptor.trailing else {
            return XCTFail("expected .problemPair trailing, got \(runningDescriptor.trailing)")
        }
        XCTAssertNil(runningSkip, "Skip must not appear mid-run since setSkipped refuses while isRunning")
        XCTAssertNil(runningRemove, "Remove must not appear mid-run since remove(_:) refuses while isRunning")

        await gate.open()
        try await waitUntil(timeout: 15) { !env.model.isRunning }

        let doneDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .problems)
        guard case .problemPair(let doneSkip, let doneRemove) = doneDescriptor.trailing else {
            return XCTFail("expected .problemPair trailing, got \(doneDescriptor.trailing)")
        }
        XCTAssertEqual(doneSkip?.title, "Skip", "Skip must return once the run ends")
        XCTAssertEqual(doneRemove?.title, "Remove", "Remove must return once the run ends")
    }

    /// Same rule again, applied to Undo on an already-skipped problem row: `setSkipped(false, …)`
    /// refuses mid-run, so the row is absent its Undo button for the run's duration.
    func testSkippedRowHidesUndoWhileRunningThenShowsItAfter() async throws {
        let env = try HeavyEnv()
        let gate = Gate()
        env.stub.gate = gate
        // `skippedRows` is pruned to live job IDs (`publishJobs`'s own filter), so the marked row
        // must be a real queued job, not a synthetic one — mark it BEFORE the run starts, since
        // `setSkipped` refuses mid-run. A second, non-skipped row drives the actual run (a
        // skipped row is excluded from arming, so it alone would never make `isRunning` true).
        let jobID = try await env.addRow()
        env.model.setSkipped(true, for: jobID)
        _ = try await env.addRow()

        env.model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        XCTAssertTrue(env.model.isRunning)

        guard var job = env.model.jobs.first(where: { $0.id == jobID }) else {
            return XCTFail("expected the added row to still be present")
        }
        job.state = .failed(CompressError.encrypted.localizedDescription)
        let runningDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .working)
        guard case .skipped(let runningUndo) = runningDescriptor.trailing else {
            return XCTFail("expected .skipped trailing, got \(runningDescriptor.trailing)")
        }
        XCTAssertNil(runningUndo, "Undo must not appear mid-run since setSkipped refuses while isRunning")

        await gate.open()
        try await waitUntil(timeout: 15) { !env.model.isRunning }

        let doneDescriptor = QueueRowsView.describe(job: job, model: env.model, state: .problems)
        guard case .skipped(let doneUndo) = doneDescriptor.trailing else {
            return XCTFail("expected .skipped trailing, got \(doneDescriptor.trailing)")
        }
        XCTAssertEqual(doneUndo?.title, "Undo", "Undo must return once the run ends")
    }

    /// A run-time locked failure gets the same "Needs a password to open" copy and danger tint as
    /// add-time inspection — Skip/Remove only, never "Find it…" (D3: no password entry).
    func testRunTimeLockedFailureGetsPasswordCopyAndDangerTint() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        job.state = .failed(CompressError.encrypted.localizedDescription)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .problems)
        XCTAssertEqual(descriptor.meta, "Needs a password to open")
        XCTAssertEqual(descriptor.emphasis, .problemDanger)
        guard case .problemPair(let first, let second) = descriptor.trailing else {
            return XCTFail("expected .problemPair (Skip/Remove), got \(descriptor.trailing)")
        }
        XCTAssertEqual(first?.title, "Skip")
        XCTAssertEqual(second?.title, "Remove")
    }

    /// A genuine run-time-only failure (no add-time equivalent) keeps its own engine message and
    /// the pre-existing Skip/Remove danger treatment — the mapping must not swallow these.
    func testRunTimeCompressOnlyFailureKeepsItsOwnMessage() {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        var job = ToolJob(url: URL(fileURLWithPath: "/tmp/gs-failed.pdf"))
        job.state = .failed("Couldn't be compressed")
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .problems)
        XCTAssertEqual(descriptor.meta, "Couldn't be compressed")
        XCTAssertEqual(descriptor.emphasis, .problemDanger)
    }

    /// `RowProblem.problemCopy` is the one table both add-time inspection and the run-time second
    /// net read — this is the reverse direction (copy → problem) exercised via `RowInspection`,
    /// confirming the two never diverge in wording.
    func testProblemCopyMatchesRowInspectionMetaLineForEachCondition() {
        for problem: RowProblem in [.locked, .missing, .unreadable] {
            XCTAssertEqual(RowInspection(problem: problem).metaLine, problem.problemCopy,
                            "\(problem) must read identically whether add-time or run-time")
        }
    }

    // MARK: per-file override surfacing (spec §7, DESIGN.md §9 04c)

    /// An overridden queued row's meta gets the accent "Its own settings" — the popover's own
    /// "Match the batch" is what clears it.
    func testOverriddenRowGetsItsOwnSettingsMetaAccent() throws {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        model.add([try Fixtures.bornDigitalPDF()])
        let job = try XCTUnwrap(model.jobs.first)
        model.setOverride(RowOverride(rebuildScan: true), for: job.id)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .ready)
        XCTAssertEqual(descriptor.metaAccent, "Its own settings")
    }

    /// A row matching the batch (no override) never gets the accent.
    func testUnoverriddenRowHasNoMetaAccent() throws {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        model.add([try Fixtures.bornDigitalPDF()])
        let job = try XCTUnwrap(model.jobs.first)
        let descriptor = QueueRowsView.describe(job: job, model: model, state: .ready)
        XCTAssertNil(descriptor.metaAccent)
    }

    /// The ready footer's subline notes the divergence iff any row has its own settings — singular
    /// wording is the handoff's pinned string (DESIGN.md §9 04c); several overrides get a
    /// truthful plural, recorded as a divergence (no plural form is pinned).
    func testReadyFooterNotesDivergenceOnlyWhenOverridesExist() throws {
        let model = QueueViewModel(engine: nil, history: makeHermeticHistory())
        model.add([try Fixtures.bornDigitalPDF(), try Fixtures.bornDigitalPDF()])
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(QueueFooterView.readySubline(model: model), "Your originals stay exactly where they are.")

        model.setOverride(RowOverride(rebuildScan: true), for: model.jobs[0].id)
        XCTAssertEqual(QueueFooterView.readySubline(model: model),
                       "One file has its own settings, so its estimate differs from the batch.")

        model.setOverride(RowOverride(rebuildScan: true), for: model.jobs[1].id)
        XCTAssertEqual(QueueFooterView.readySubline(model: model),
                       "2 files have their own settings, so their estimates differ from the batch.")
    }

    // MARK: problems header count (spec §7) — delivered-of-total, never problem/failed rows counted as done

    /// The exact repro: a `.failed` row and an unresolved `.locked` row must not inflate the
    /// numerator — only the one row that actually delivered counts as "done".
    func testProblemsHeadlineCountsOnlyDeliveredRowsNeverFailedOrUnresolved() {
        var delivered = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        delivered.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        var failed = ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))
        failed.state = .failed("Couldn't be compressed")
        let locked = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        XCTAssertEqual(QueueHeaderView.problemsHeadline(jobs: [delivered, failed, locked]),
                       "1 of 3 files done")
    }

    /// Screen 10's own render: five rows, three actually delivered — never "3 of 3" (row count),
    /// always delivered-of-total.
    func testProblemsHeadlineReadsDeliveredOfTotalNotRowCountOfRowCount() {
        var jobs: [ToolJob] = []
        for i in 0..<3 {
            var job = ToolJob(url: URL(fileURLWithPath: "/tmp/done\(i).pdf"))
            job.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
            jobs.append(job)
        }
        jobs.append(ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf")))
        jobs.append(ToolJob(url: URL(fileURLWithPath: "/tmp/missing.pdf")))
        XCTAssertEqual(QueueHeaderView.problemsHeadline(jobs: jobs), "3 of 5 files done")
    }

    /// The paired sub-line partitions the SAME rows: 1 delivered, 1 locked-unresolved, 1
    /// moved-unresolved (missing) ⇒ "1 of 3 files done" + "2 files need something from you".
    func testProblemsHeadlineAndSubtitleAgreeOnTheSameRowPartition() {
        var delivered = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        delivered.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        let locked = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let moved = ToolJob(url: URL(fileURLWithPath: "/tmp/moved.pdf"))
        let inspections = [locked.id: RowInspection(problem: .locked), moved.id: RowInspection(problem: .missing)]
        let jobs = [delivered, locked, moved]

        XCTAssertEqual(QueueHeaderView.problemsHeadline(jobs: jobs), "1 of 3 files done")
        XCTAssertEqual(QueueHeaderView.problemsSubtitle(jobs: jobs, inspections: inspections, savedSoFarBytes: 0),
                       "2 files need something from you.")
    }

    /// Finding C repro: a skipped `.failed` row and a skipped problem row are both
    /// resolved-by-skip — the subtitle must drop them from "needs something from you", mirroring
    /// `screenState`'s own skip semantics via the shared `QueueRowPartition`.
    func testProblemsSubtitleDropsSkippedFailedAndSkippedProblemRows() {
        var delivered = ToolJob(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        delivered.state = .done(RowOutcome(originalBytes: 100, finalBytes: 50, compress: .compressed(before: 100, after: 50)))
        var skippedFailed = ToolJob(url: URL(fileURLWithPath: "/tmp/b.pdf"))
        skippedFailed.state = .failed("Couldn't be compressed")
        let skippedProblem = ToolJob(url: URL(fileURLWithPath: "/tmp/locked.pdf"))
        let inspections = [skippedProblem.id: RowInspection(problem: .locked)]
        let jobs = [delivered, skippedFailed, skippedProblem]

        XCTAssertEqual(QueueHeaderView.problemsSubtitle(jobs: jobs, inspections: inspections,
                                                        skipped: [skippedFailed.id, skippedProblem.id],
                                                        savedSoFarBytes: 0),
                       "0 files need something from you.")
    }

    // MARK: helpers

    /// Every `QueueViewModel` this file constructs directly (not via `HeavyEnv`, which already
    /// roots its own) gets a temp-directory `HistoryStore` — never the developer's real
    /// `history.json` (F6's own hermeticity rule).
    private func makeHermeticHistory() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("qvst-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeView(model: QueueViewModel) -> QueueView {
        QueueView(model: model, history: model.history, showAbout: .constant(false))
    }
}
