// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import Toolbox

/// The single pass one file makes through the queue (spec §6.2/§6.4/§6.5/§6.8): compress leg,
/// cancellation boundary, OCR leg against the ORIGINAL with the layer appended to every variant
/// the job delivers, then the commit that re-stats what it wrote and records what each file can
/// honestly claim.
///
/// Two kinds of test live here on purpose. The **layer** tests run the REAL `OCREngine` over a
/// stub-delivered but genuinely valid PDF, because nothing less proves a variant carries
/// extractable text. Everything else — dispositions, reservations, flags, the width-2 bound —
/// runs `StubOCREngine`, which is fast and can be gated mid-leg.
///
/// `OCRViewModelTests.testCancelStopsTheViewModelsQueue` is SUPERSEDED by `testCancelStopsQueue`
/// below: the OCR tool's own view model dies with the sidebar (spec §6.11), and its cancel
/// semantics belong to the unified queue from here on.
@MainActor
final class QueuePassTests: XCTestCase {

    // MARK: recognition fixtures

    /// A recognition of a one-page document. `runs` empty with `pagesRecognised: 0` is the
    /// already-searchable shape; empty with `pagesRecognised: 1` is the too-faint one.
    private func recognition(runs: [String] = ["HELLO"],
                             pagesRecognised: Int = 1,
                             pagesSkipped: Int = 0,
                             pageCount: Int = 1) -> RecognisedDocument {
        var pageText: [Int: [PositionedText]] = [:]
        if !runs.isEmpty {
            pageText[0] = runs.map {
                PositionedText(text: $0,
                               boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))
            }
        }
        return RecognisedDocument(pageText: pageText,
                                  geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
                                  pagesRecognised: pagesRecognised,
                                  pagesSkipped: pagesSkipped,
                                  pageCount: pageCount)
    }

    private var added: RecognisedDocument { recognition() }
    private var alreadySearchable: RecognisedDocument {
        recognition(runs: [], pagesRecognised: 0, pagesSkipped: 1)
    }
    private var tooFaint: RecognisedDocument { recognition(runs: [], pagesRecognised: 1) }
    /// Every run beyond WinAnsi's Latin-1 range: the layer cannot be embedded without turning the
    /// user's text into `?` (the pre-existing writer limitation, routed here from F3).
    private var allLossy: RecognisedDocument { recognition(runs: ["中文文档", "СПРАВКА"]) }

    // MARK: environment

    /// A queue with both verbs on, the shared heavy-pair compress stub, and a scripted OCR double.
    private func env(_ document: RecognisedDocument,
                     before: Int = 9000) throws -> (env: HeavyEnv, ocr: StubOCREngine) {
        let ocr = StubOCREngine(document: document)
        let env = try HeavyEnv(before: before, ocrEngine: ocr)
        env.model.ocrOn = true
        return (env, ocr)
    }

    private func outcome(_ model: QueueViewModel, _ id: ToolJob.ID) -> RowOutcome? {
        guard let job = model.jobs.first(where: { $0.id == id }),
              case .done(let outcome) = job.state else { return nil }
        return outcome
    }

    private func job(_ model: QueueViewModel, _ id: ToolJob.ID) throws -> ToolJob {
        try XCTUnwrap(model.jobs.first(where: { $0.id == id }))
    }

    private func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: the layer actually lands (real OCREngine)

    /// One file, one row, both verbs: the compress artefact ships and the text layer lands ON the
    /// file the user gets — the whole point of running the legs in one pass (spec §6.2).
    func testCompressThenOCRSingleRow() async throws {
        let env = try HeavyEnv()                        // the real `OCREngine`
        let model = env.model
        model.ocrOn = true
        let input = try Fixtures.textImagePDF()
        let payload = try TestSupport.tinyValidPDF(matching: input)
        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: payload.count),
                  shippedBytes: nil, runnerUpBytes: nil, shippedPayload: payload)
        }
        let id = try await env.addRow(input)

        model.compress()
        try await waitUntil(timeout: 120) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.compress, .compressed(before: 9_000, after: payload.count))
        XCTAssertEqual(result.ocr, .added(pages: 1, skipped: 0))
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(try PDFService().pageHasText(delivered, index: 0),
                      "the delivered file must carry the layer, not merely the row's claim")
        XCTAssertEqual(model.versions(for: try job(model, id))?.searchableByCard[.shipped], true)
        XCTAssertEqual(result.finalBytes, TestSupport.fileSize(delivered),
                       "the commit re-stats the delivered file after the append")
        XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: input, in: input),
                      "sanity: the original is readable")
    }

    /// The layer is appended to EVERY variant the job delivers (spec §6.4's fatal): a switch to the
    /// runner-up must hand over a file that genuinely reads, not one whose row says it does.
    func testOCRAppliedToRunnerUpVariant() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.ocrOn = true
        let input = try Fixtures.textImagePDF()
        let payload = try TestSupport.tinyValidPDF(matching: input)
        env.stub.script = { _, _ in
            .init(outcome: .compressedHeavy(before: 9_000, after: payload.count,
                                            runnerUpBytes: payload.count + 1),
                  shippedBytes: nil, runnerUpBytes: nil,
                  shippedPayload: payload, runnerUpPayload: payload)
        }
        let id = try await env.addRow(input)

        model.compress()
        try await waitUntil(timeout: 120) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        let shipped = try XCTUnwrap(row.shipped?.url)
        let runnerUp = try XCTUnwrap(row.runnerUp?.url)
        for url in [shipped, runnerUp] {
            XCTAssertTrue(try PDFService().pageHasText(url, index: 0),
                          "\(url.lastPathComponent) must carry the appended layer")
        }
        XCTAssertEqual(row.searchableByCard[.shipped], true)
        XCTAssertEqual(row.searchableByCard[.runnerUp], true)
    }

    // MARK: the original is never appended to (spec §6.4)

    /// When the parked variant IS the untouched input (gs bloated — R6/R7), the original-untouched
    /// invariant wins: no layer is ever added to it, and its card says so.
    func testOriginalVariantNeverAppended() async throws {
        let (env, ocr) = try env(added, before: HeavyEnv.normalBytes)
        ocr.growthBytes = 128
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.runnerUp?.variant, .original, "the fixture must park the input itself")
        let parked = try XCTUnwrap(row.runnerUp?.url)
        XCTAssertFalse(ocr.appendTargets.contains(parked),
                       "the untouched original is never appended to")
        XCTAssertEqual(TestSupport.fileSize(parked), HeavyEnv.normalBytes,
                       "and its bytes are exactly as the compress leg left them")
        XCTAssertEqual(row.searchableByCard[.runnerUp], false,
                       "an original that was not already searchable carries no claim of it")
    }

    /// Each card's flag comes from THAT file's own append result — one variant can fail while the
    /// other lands (spec §6.4). A row whose OCR verb never ran writes no flags at all.
    func testSearchableByCardReflectsAppendOutcomes() async throws {
        let (env, ocr) = try env(added)
        ocr.throwOnAppendCall = 1                        // the delivered file, appended first
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false,
                       "the variant that could not carry the layer is labelled honestly")
        XCTAssertEqual(row.searchableByCard[.runnerUp], true)
        XCTAssertEqual(row.searchableByCard[.originalReference], false)
        if case .failed = try job(model, id).state {
            XCTFail("an append failure is never a job failure")
        }
        XCTAssertEqual(try XCTUnwrap(outcome(model, id)).ocr, .added(pages: 1, skipped: 0),
                       "and the leg still reports what it read")
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), HeavyEnv.heavyBytes,
                       "the failed append left the compress artefact exactly as it was")

        // The absence assertion (spec §11): a compress-only row claims nothing in either direction.
        let plain = try HeavyEnv()
        let plainID = try await plain.addRow()
        plain.model.compress()
        try await waitUntil(timeout: 15) { !plain.model.isRunning }
        XCTAssertTrue(try XCTUnwrap(plain.model.versions(for: try job(plain.model, plainID)))
            .searchableByCard.isEmpty,
                      "no OCR leg ran, so the row carries no searchability claim")
    }

    /// The counterintuitive but legal pair (spec §6.4, amended 2026-07-30): the compress leg
    /// rasterised the pages, so the file the user got cannot be searched, while the input it came
    /// from could — and the Original row says so because the leg returned `.alreadySearchable`.
    func testShippedUnsearchableOriginalSearchableCorollary() async throws {
        let (env, ocr) = try env(alreadySearchable)
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(ocr.appendCallCount, 0, "there is nothing to add to any variant")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false)
        XCTAssertEqual(row.searchableByCard[.originalReference], true,
                       "the Original label is outcome-keyed: `.alreadySearchable` is the evidence")
        XCTAssertEqual(try XCTUnwrap(outcome(model, id)).ocr, .alreadySearchable)
    }

    /// A recognition whose every run would be destroyed by the WinAnsi text layer is not written at
    /// all — a `?` layer that passes validation is the misrepresentation §6.4 forbids. The row's
    /// state is untouched: an unappendable variant is reported through its LABEL, never through the
    /// row (`RowOutcome.isDegraded`'s own rule).
    func testAllLossyRecognitionSkipsAppendAndLabelsUnsearchable() async throws {
        let (env, ocr) = try env(allLossy)
        ocr.growthBytes = 64
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(ocr.appendCallCount, 0, "no variant may receive a layer of `?`")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false)
        XCTAssertEqual(row.searchableByCard[.runnerUp], false)
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), HeavyEnv.heavyBytes,
                       "the delivered file is exactly what the compress leg wrote")
        XCTAssertFalse(try XCTUnwrap(outcome(model, id)).isDegraded,
                       "a variant that cannot carry the layer is a LABEL fact, not a row state")
    }

    // MARK: the compress-failure rescue (spec §6.5)

    /// A compress-specific failure with OCR on does not fail the job: the `-compressed` reservation
    /// goes back, `<name>-ocr.pdf` is reserved through the same ledger, and the OCR leg runs against
    /// the original.
    func testCompressFailureContinuesOCRLeg() async throws {
        let (env, ocr) = try env(added)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        let model = env.model
        let id = try await env.addRow()
        let compressedName = try XCTUnwrap(model.reservedDelivery(for: id))

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.compress, .skipped(problem: .compressFailed))
        XCTAssertEqual(result.ocr, .added(pages: 1, skipped: 0))
        XCTAssertEqual(ocr.appendTargets, [env.input], "the rescue reads and writes the ORIGINAL")
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(delivered.lastPathComponent.hasSuffix("-ocr.pdf"),
                      "a file that carries no compression is never named `-compressed`")
        XCTAssertTrue(exists(delivered))
        XCTAssertEqual(model.reservedDelivery(for: id), delivered)
        XCTAssertFalse(exists(compressedName), "nothing was ever written under the compressed name")
    }

    /// The rescued row is warn/degraded, never "failed" — the Problems footer's promise ("Files
    /// that failed were not touched at all") has to stay true.
    func testRescuedRowClassifiedWarnNotFailed() async throws {
        let (env, _) = try env(added)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertTrue(try XCTUnwrap(outcome(model, id)).isDegraded)
        if case .failed = try job(model, id).state {
            XCTFail("a rescued row must never read as failed")
        }
    }

    /// `.alreadySearchable` on the rescue leg delivers nothing: the `-ocr` reservation goes back and
    /// the row keeps the compress failure's own warn disposition.
    func testRescueAlreadySearchableShipsNothing() async throws {
        let (env, _) = try env(alreadySearchable)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.validationFailed
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.compress, .skipped(problem: .compressFailed))
        XCTAssertEqual(result.ocr, .alreadySearchable)
        XCTAssertNil(try job(model, id).resultURL, "nothing was delivered")
        XCTAssertNil(model.reservedDelivery(for: id), "and the name goes back to the ledger")
        XCTAssertTrue(result.isDegraded)
    }

    func testRescueTooFaintShipsNothing() async throws {
        let (env, _) = try env(tooFaint)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.ocr, .tooFaint)
        XCTAssertNil(try job(model, id).resultURL)
        XCTAssertNil(model.reservedDelivery(for: id))
        XCTAssertTrue(result.isDegraded, "nothing shipped and the row says so")
    }

    /// Worst case identical to no-rescue (spec §6.5): both reservations go back, nothing is
    /// delivered, the original is untouched, and the row is a problem row.
    func testRescueOCRFailureReleasesBothReservations() async throws {
        let (env, ocr) = try env(added)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        ocr.throwOnRecogniseCall = 1
        let model = env.model
        let id = try await env.addRow()
        let compressedName = try XCTUnwrap(model.reservedDelivery(for: id))
        let originalBytes = TestSupport.fileSize(env.input)

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        guard case .failed = try job(model, id).state else {
            return XCTFail("a rescue whose OCR leg failed too must fail the row")
        }
        XCTAssertNil(model.reservedDelivery(for: id))
        XCTAssertNil(model.reservedAlternate(for: id))
        XCTAssertFalse(exists(compressedName))
        XCTAssertEqual(TestSupport.fileSize(env.input), originalBytes, "the original is untouched")
    }

    /// `encrypted`/`corrupt` fail the whole job — OCR would fail identically, so there is nothing
    /// to rescue.
    func testEncryptedFailsWholeJob() async throws {
        let (env, ocr) = try env(added)
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.encrypted
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        guard case .failed = try job(model, id).state else {
            return XCTFail("an encrypted file fails the job outright")
        }
        XCTAssertEqual(ocr.recogniseCallCount, 0, "the OCR leg never runs on an unreadable file")
    }

    /// With OCR off there is no rescue to run, so a compress-specific failure fails the row — under
    /// the problem-row line the handoff has no string for (recorded divergence, owned by F5a).
    func testCompressFailureWithOCROffFailsRow() async throws {
        let env = try HeavyEnv()
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        guard case .failed(let message) = try job(model, id).state else {
            return XCTFail("a compress failure with no OCR leg fails the row")
        }
        XCTAssertEqual(message, "Couldn't be compressed")
    }

    // MARK: the noGain + OCR sibling (spec §6.5)

    /// A no-gain compress verdict with OCR on delivers original-plus-layer through the same mid-run
    /// reservation switch — and makes no savings claim.
    func testNoGainWithOCRDeliversOcrName() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 256
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.compress, .noGain(bytes: 9_000))
        XCTAssertEqual(result.ocr, .added(pages: 1, skipped: 0))
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(delivered.lastPathComponent.hasSuffix("-ocr.pdf"))
        XCTAssertTrue(exists(delivered))
        XCTAssertNil(model.displayedSizes(for: try job(model, id)),
                     "an OCR-only delivery makes no before/after claim")
    }

    func testNoGainAlreadySearchableShipsNothing() async throws {
        let (env, _) = try env(alreadySearchable)
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.ocr, .alreadySearchable)
        XCTAssertNil(try job(model, id).resultURL)
        XCTAssertNil(model.reservedDelivery(for: id))
        XCTAssertNil(model.reservedAlternate(for: id))
        XCTAssertFalse(result.isDegraded, "already optimised and already searchable is not a warning")
    }

    func testNoGainTooFaintShipsNothing() async throws {
        let (env, _) = try env(tooFaint)
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.ocr, .tooFaint)
        XCTAssertNil(try job(model, id).resultURL)
        XCTAssertNil(model.reservedDelivery(for: id))
        XCTAssertTrue(result.isDegraded)
    }

    func testNoGainOCRFailureReleasesBothReservations() async throws {
        let (env, ocr) = try env(added)
        ocr.throwOnRecogniseCall = 1
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()
        let originalBytes = TestSupport.fileSize(env.input)

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        guard case .failed = try job(model, id).state else {
            return XCTFail("nothing could be delivered, so the row fails")
        }
        XCTAssertNil(model.reservedDelivery(for: id))
        XCTAssertNil(model.reservedAlternate(for: id))
        XCTAssertEqual(TestSupport.fileSize(env.input), originalBytes, "the original is untouched")
    }

    // MARK: degraded, never failed (spec §7)

    /// A read that fails AFTER the compress delivery never fails the job: the compressed file is
    /// kept and banked, and the row carries the caveat.
    func testCompressDeliveredOCRRecogniseFailureIsDegradedNotFailed() async throws {
        let (env, ocr) = try env(added)
        ocr.throwOnRecogniseCall = 1
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        guard case .failed = result.ocr else {
            return XCTFail("the row must record the read failure, got \(String(describing: result.ocr))")
        }
        XCTAssertTrue(result.isDegraded)
        if case .failed = try job(model, id).state { XCTFail("the delivered file is banked, not lost") }
        XCTAssertTrue(exists(try job(model, id).resultURL))
    }

    // MARK: cancellation boundaries (spec §6.5)

    /// Cancelled between the legs: the compress delivery was atomic and complete, so it is kept and
    /// banked, and the row says why it is not searchable.
    func testCancelBetweenLegsBanksCompressed() async throws {
        let (env, ocr) = try env(added)
        let gate = Gate()
        env.stub.gate = gate
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(result.ocr, .cancelled, "never nil — the verb was on and the leg was cut")
        XCTAssertEqual(ocr.recogniseCallCount, 0)
        XCTAssertTrue(exists(try job(model, id).resultURL), "the delivered file is kept")
        XCTAssertTrue(result.isDegraded)
    }

    /// The same boundary on a row that delivered NOTHING: there is nothing to bank, so it takes the
    /// queue's own cancel semantics and returns to `.queued`. Marking it finished would report a
    /// file the batch never touched as done, under a caveat about a leg that never ran.
    func testCancelBetweenLegsRequeuesARowThatDeliveredNothing() async throws {
        let (env, ocr) = try env(added)
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(ocr.recogniseCallCount, 0)
        switch try job(model, id).state {
        case .queued, .analysing: break
        case let other: XCTFail("a row that delivered nothing must go back to the queue, got \(other)")
        }
        XCTAssertNotNil(model.reservedDelivery(for: id), "and it keeps the name it reserved")
    }

    /// The same boundary with the OCR verb OFF: the row completes normally and keeps its file —
    /// a cancel landing between the engine's return and the commit must never discard delivered
    /// work, nor invent a cancelled OCR leg that was never going to run.
    func testCancelBetweenEngineReturnAndCommit() async throws {
        let env = try HeavyEnv()
        let gate = Gate()
        env.stub.gate = gate
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertNil(result.ocr, "the verb was off; there is no leg to report on")
        XCTAssertTrue(exists(try job(model, id).resultURL))
    }

    /// SUCCESSOR to `OCRViewModelTests.testCancelStopsTheViewModelsQueue`: after a cancel no
    /// further job starts, and the rows that never ran are left exactly as they were.
    func testCancelStopsQueue() async throws {
        let width = SystemInfo.performanceCoreCount
        try XCTSkipIf(width < 2, "needs more than one performance core to leave a row unstarted")
        let (env, _) = try env(added)
        let gate = Gate()
        env.stub.gate = gate
        let model = env.model
        model.add(Array(repeating: env.input, count: width + 2))
        try await waitUntil(timeout: 10) { model.jobs.count == width + 2 }

        model.compress()
        try await waitUntil(timeout: 20) { env.stub.callCount == width }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 20) { !model.isRunning }

        XCTAssertEqual(env.stub.callCount, width, "no job may start after the cancel")
        // Pending, not bare `.queued`: `.analysing` is the view model's own overlay on a row the
        // queue still holds as queued, and the estimates for a batch this size legitimately outlast
        // the run (they are time-boxed and queued behind each other).
        let untouched = model.jobs.filter {
            switch $0.state {
            case .queued, .analysing: return true
            default: return false
            }
        }
        XCTAssertEqual(untouched.count, 2, "the rows that never ran stay queued")
    }

    // MARK: the OCR leg's width-2 bound (spec §6.8)

    /// The memory bound `OCRViewModel` pinned lives on the queue's OCR leg now: at most two files
    /// are read at once, whatever the batch width.
    func testOCRSemaphoreWidthTwo() async throws {
        try XCTSkipIf(SystemInfo.performanceCoreCount < 3,
                      "needs ≥3 performance cores to observe a cap of 2")
        let (env, ocr) = try env(added)
        let gate = Gate()
        ocr.gate = gate
        let model = env.model
        model.add(Array(repeating: env.input, count: 4))
        try await waitUntil(timeout: 10) { model.jobs.count == 4 }

        model.compress()
        try await waitUntil(timeout: 20) { ocr.recogniseCallCount == 2 }
        // Held long enough for a third to arrive if the bound were not there: every compress leg
        // has already returned by now (the stub is ungated), so the only thing keeping the other
        // rows out of the OCR leg is the semaphore.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ocr.recogniseCallCount, 2, "a third read must wait for a slot")

        await gate.open()
        try await waitUntil(timeout: 20) { !model.isRunning }
        XCTAssertEqual(ocr.peakConcurrent, 2, "and the cap holds across the whole batch")
        XCTAssertEqual(ocr.recogniseCallCount, 4, "every row is still read, just two at a time")
    }

    // MARK: the commit's per-artefact re-stat (spec §6.4)

    /// The engine reports the COMPRESS artefact's size; the append then grows the file. The commit
    /// re-stats what it actually delivered — a pre-append number on the row is the wrong number.
    func testFinalBytesRestatedAfterAppend() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 777
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertEqual(TestSupport.fileSize(delivered), HeavyEnv.heavyBytes + 777)
        XCTAssertEqual(result.finalBytes, HeavyEnv.heavyBytes + 777)
        XCTAssertEqual(result.compress, .compressed(before: 9_000, after: HeavyEnv.heavyBytes),
                       "the compress leg's own numbers stay what the engine measured")
    }

    /// The consent sheet's two cards must be measured at the same moment, so the retained variant
    /// is re-stat'd too.
    func testRunnerUpBytesRestatedAfterAppend() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 333
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        let parked = try XCTUnwrap(row.runnerUp?.url)
        XCTAssertEqual(TestSupport.fileSize(parked), HeavyEnv.normalBytes + 333)
        XCTAssertEqual(row.runnerUp?.bytes, HeavyEnv.normalBytes + 333)
        XCTAssertEqual(try XCTUnwrap(outcome(model, id)).runnerUp?.bytes,
                       HeavyEnv.normalBytes + 333)
    }

    /// The shipped card is the delivered file, so its bytes are the row's own `finalBytes`.
    func testShippedCardBytesMatchRowFinalBytes() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 111
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.bytes, try XCTUnwrap(outcome(model, id)).finalBytes)
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.heavyBytes + 111)
    }

    /// An OCR-only run compresses nothing, so it claims nothing: grey "no change" sizes, never a
    /// before/after pair (spec §6.3).
    func testOCROnlyRowNoSizeLie() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 512
        let model = env.model
        model.compressOn = false
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let result = try XCTUnwrap(outcome(model, id))
        XCTAssertEqual(env.stub.callCount, 0, "the compress verb is off")
        XCTAssertNil(result.compress)
        XCTAssertEqual(result.ocr, .added(pages: 1, skipped: 0))
        XCTAssertNil(model.displayedSizes(for: try job(model, id)),
                     "an OCR-only row must not report a saving it never made")
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(delivered.lastPathComponent.hasSuffix("-ocr.pdf"))
        XCTAssertEqual(result.finalBytes, TestSupport.fileSize(delivered),
                       "the sizes it DOES carry are the real ones")
        XCTAssertEqual(result.originalBytes, TestSupport.fileSize(env.input))
    }

    // MARK: selecting the Original reference row (design screen 07)

    /// A finished heavy row plus its delivered file — the starting point for the switch tests.
    private func switchable() async throws -> (env: HeavyEnv, id: ToolJob.ID) {
        let env = try HeavyEnv()
        try await env.runToDone()
        return (env, try XCTUnwrap(env.model.jobs.first).id)
    }

    /// The original is COPIED into the delivered slot, never moved: the user's own file stays
    /// exactly where it is.
    func testUseOriginalReferenceCopiesNeverMoves() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        let originalBytes = TestSupport.fileSize(env.input)

        await model.useCard(.originalReference, for: try job(model, id))

        XCTAssertTrue(exists(env.input), "the input file is never moved out of its own folder")
        XCTAssertEqual(TestSupport.fileSize(env.input), originalBytes)
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .original)
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), originalBytes,
                       "the delivered file now holds the original's content")
    }

    /// The switch parks the version the user had into `previous`, replacing (and discarding) any
    /// occupant — the cap stays at two parked versions (spec §5).
    func testUseOriginalParksShippedIntoPreviousReplacingOccupant() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let id = try XCTUnwrap(model.jobs.first).id
        // A re-run at another preset parks the first result into `previous`.
        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: 2_000),
                  shippedBytes: 2_000, runnerUpBytes: nil)
        }
        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }
        let occupant = try XCTUnwrap(model.versions(for: try job(model, id))?.previous?.url)
        XCTAssertTrue(exists(occupant))

        await model.useCard(.originalReference, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .original)
        XCTAssertEqual(row.previous?.bytes, 2_000, "the version they had is the one parked")
        XCTAssertNotEqual(row.previous?.url, occupant)
        XCTAssertFalse(exists(occupant), "the superseded park is discarded, never accumulated")
    }

    /// The flags describe the BYTES, so they travel with them: the demoted file keeps its claim and
    /// the newly-shipped original takes the Original row's.
    func testUseOriginalReferenceMovesSearchableFlags() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 32
        let model = env.model
        let id = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }
        XCTAssertEqual(model.versions(for: try job(model, id))?.searchableByCard[.shipped], true)

        await model.useCard(.originalReference, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.previous], true,
                       "the compressed file kept its layer and its claim")
        XCTAssertEqual(row.searchableByCard[.shipped], false,
                       "the original was never appended to, so the row's claim downgrades honestly")
    }

    /// A compress-only row carries no searchability claim in either direction, and switching to the
    /// original must not manufacture one.
    func testUseOriginalOnCompressOnlyRowWritesNoLabels() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        XCTAssertTrue(try XCTUnwrap(model.versions(for: try job(model, id))).searchableByCard.isEmpty)

        await model.useCard(.originalReference, for: try job(model, id))

        XCTAssertTrue(try XCTUnwrap(model.versions(for: try job(model, id))).searchableByCard.isEmpty,
                      "a `?? false` default here would invent a claim the row has no evidence for")
    }

    /// Once the original IS what shipped, the reference row is gone from the list — never two rows
    /// for one file.
    func testOriginalReferenceHiddenWhenShippedIsOriginal() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        XCTAssertTrue(try XCTUnwrap(model.versions(for: try job(model, id)))
            .cards.contains { $0.key == .originalReference })

        await model.useCard(.originalReference, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertFalse(row.cards.contains { $0.key == .originalReference })
        XCTAssertEqual(row.shipped?.variant, .original)
    }

    /// And a second click is a no-op rather than a second park, which would list the original twice
    /// and discard the compressed version the first click preserved.
    func testSecondUseOriginalIsNoOpAndKeepsCompressedVersion() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        await model.useCard(.originalReference, for: try job(model, id))
        let parked = try XCTUnwrap(model.versions(for: try job(model, id))?.previous)

        await model.useCard(.originalReference, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.previous, parked, "the compressed version they kept is still there")
        XCTAssertTrue(exists(parked.url))
        XCTAssertEqual(row.shipped?.variant, .original)
    }

    /// The guard is taken in the synchronous prefix, before the first suspension — two taps land
    /// exactly one switch.
    func testSecondUseOriginalWhileFirstInFlightIsIgnored() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        let target = try job(model, id)

        async let first: Void = model.useCard(.originalReference, for: target)
        async let second: Void = model.useCard(.originalReference, for: target)
        _ = await (first, second)

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .original)
        XCTAssertEqual(row.previous?.bytes, HeavyEnv.heavyBytes,
                       "a second, racing switch would have parked the original over the compressed one")
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)),
                       TestSupport.fileSize(env.input))
    }

    /// Delegation must actually delegate: `useCard` takes no guard of its own for a parked slot,
    /// because `useVersion` owns both the guard and the insert — taking it twice would make every
    /// runner-up switch a silent no-op.
    func testUseCardDelegatesRunnerUpSwitchSuccessfully() async throws {
        let (env, id) = try await switchable()
        let model = env.model

        await model.useCard(.runnerUp, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .plain, "the delegated switch must land")
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), HeavyEnv.normalBytes)
    }

    /// `.shipped` is already in use: no guard, no insert, no state change.
    func testUseShippedCardIsANoOp() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        let before = try XCTUnwrap(model.versions(for: try job(model, id)))

        await model.useCard(.shipped, for: try job(model, id))

        XCTAssertEqual(model.versions(for: try job(model, id)), before)
        XCTAssertTrue(model.switchesInFlight.isEmpty)
    }

    /// A promote that throws an ordinary error leaves the shipped file untouched by the store's
    /// contract, so the row records NOTHING — a version record written against a switch that did
    /// not happen is the mislabel the store exists to prevent.
    func testUseOriginalReferencePromoteFailureRecordsNothing() async throws {
        let (env, id) = try await switchable()
        let model = env.model
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        let shipped = try XCTUnwrap(row.shipped?.url)
        // The delivered file is gone (deleted outside the app), so the park step throws.
        try FileManager.default.removeItem(at: shipped)

        await model.useCard(.originalReference, for: try job(model, id))

        let after = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(after.shipped?.variant, .mrc, "the record is exactly as it was")
        XCTAssertNil(after.previous, "nothing was parked")
        XCTAssertNotNil(model.recompressErrors[id], "an explicit button press never fails silently")
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: shipped.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".toolbox-original-") }
        XCTAssertTrue(leftovers.isEmpty, "the abandoned copy is cleaned up")
    }
}
