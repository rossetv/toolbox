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
