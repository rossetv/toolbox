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
    /// wording is the handoff's pinned string (DESIGN.md §9 04c/§15); several overrides get a
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

    // MARK: helpers

    /// Every `QueueViewModel` this file constructs directly (not via `HeavyEnv`, which already
    /// roots its own) gets a temp-directory `HistoryStore` — never the developer's real
    /// `history.json` (F6's own hermeticity rule).
    private func makeHermeticHistory() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("qvst-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeView(model: QueueViewModel) -> QueueView {
        QueueView(
            model: model, history: model.history,
            quality: { AnyView(EmptyView()) }, ocrOptions: { AnyView(EmptyView()) },
            perFile: { _ in AnyView(EmptyView()) }, versions: { _ in AnyView(EmptyView()) },
            changeQuality: { AnyView(EmptyView()) }, scanConsent: { _ in AnyView(EmptyView()) },
            recentBatches: { AnyView(EmptyView()) }, about: { AnyView(EmptyView()) },
            showAbout: .constant(false)
        )
    }
}
