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

    /// `.alreadySearchable` is the engine's statement that EVERY page already carried extractable
    /// text (`RecognisedDocument.outcome`), and the file the user gets keeps it: gs's arguments
    /// strip no text (`CompressPreset.gsArguments`), Rung 2 re-embeds an extracted layer and
    /// verifies it or declines to gs (`CompressEngine.bilevelCompress`), and Rung 3's R2 sweep
    /// refuses any text-bearing page outright (`MRCClassifier.structure`). So the delivered card
    /// carries the same evidence the Original's does.
    ///
    /// SUPERSEDES `testShippedUnsearchableOriginalSearchableCorollary`, which asserted `false` here
    /// on this same fixture from a premise no engine can produce ("the compress leg rasterised the
    /// pages" — every rebuild rung declines a page that carries text, so an `.alreadySearchable`
    /// document is never rebuilt). Spec §6.4's corollary — a shipped card reading "not searchable"
    /// beside a searchable neighbour — keeps the paths that genuinely produce it: an append that
    /// failed (`testSearchableByCardReflectsAppendOutcomes`) and the switch to Original, which
    /// moves each flag onto the bytes it describes (`testUseOriginalReferenceMovesSearchableFlags`).
    func testAlreadySearchableLabelsTheDeliveredFileSearchableToo() async throws {
        let (env, ocr) = try env(alreadySearchable)
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(ocr.appendCallCount, 0, "there is nothing to add to any variant")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], true,
                       "the delivered file still reads — denying it is the criterion-3 lie")
        // The retained variant answers from the same evidence: a compress variant is no more
        // rasterised than the delivered one, so the row's cards cannot disagree with each other.
        // Stub-constructible only — a real runner-up needs MRC to have run, which this outcome
        // precludes — so this pins the flag's rule, never a state the engine can reach.
        XCTAssertEqual(row.searchableByCard[.runnerUp], true)
        XCTAssertEqual(row.searchableByCard[.originalReference], true,
                       "the Original label is outcome-keyed: `.alreadySearchable` is the evidence")
        XCTAssertEqual(try XCTUnwrap(outcome(model, id)).ocr, .alreadySearchable)
    }

    /// The count means what its copy says. Labelling the delivered file searchable (above) is a
    /// statement about the FILE; "N files are now searchable" and the history's "made searchable"
    /// are claims about what this run DID, and it did nothing to a document that arrived with its
    /// own text layer. The card and the count therefore read the same flags and answer differently.
    func testAnAlreadySearchableFileIsNotCountedAsOneTheRunMadeSearchable() async throws {
        let (env, _) = try env(alreadySearchable)
        let model = env.model
        _ = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(model.searchableRowCount, 0,
                       "the file arrived searchable — this run did not make it so")
    }

    /// The other outcomes on the same no-append arm are untouched: `.tooFaint` read the pages and
    /// found nothing usable, so no card may claim a layer in either direction.
    func testTooFaintStillLabelsEveryCardUnsearchable() async throws {
        let (env, ocr) = try env(tooFaint)
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(ocr.appendCallCount, 0, "there was nothing usable to add")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false)
        XCTAssertEqual(row.searchableByCard[.runnerUp], false)
        XCTAssertEqual(row.searchableByCard[.originalReference], false)
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

        // A problem batch still records — spec §6.9's "history/problem rows remain the frequency
        // signal for systemic gs failures" — with `problem` true and no savings claim, distinct
        // from a recompress-only pass's zero-savings silence (that one has no `problem`/`partial`
        // fact to report at all, which is what makes it uninteresting; this one does).
        let recorded = try XCTUnwrap(env.history.batches.first)
        XCTAssertTrue(recorded.problem)
        XCTAssertFalse(recorded.partial, "a failed row is not degraded — it is a problem")
        XCTAssertEqual(recorded.savedBytes, 0)
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

        // The OCR-only leg's searchability flags must land on a real store row, not be
        // discarded: `describeDone` reads exactly this row to render the delivery honestly
        // instead of lying "Already optimised" with a blank size (major review finding).
        let theJob = try job(model, id)
        let row = try XCTUnwrap(model.versions(for: theJob),
                                "an OCR-only row must still record a VersionStore entry")
        XCTAssertNil(row.shipped, "no compress artefact, so no version pair to offer")
        XCTAssertEqual(row.searchableByCard[.shipped], true)
        let descriptor = QueueRowsView.describe(job: theJob, model: model, state: .finished)
        XCTAssertEqual(descriptor.meta, "Already optimised · made searchable")
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

    /// The switch parks the version the user had, and with BOTH parked slots already full there is
    /// nowhere to put it but over an occupant — which is then discarded, never accumulated. The cap
    /// is two parked versions (spec §5), and this is where it genuinely binds.
    ///
    /// SUPERSEDES the free-slot half of `testUseOriginalParksShippedIntoPreviousReplacingOccupant`,
    /// which drove this same path with the runner-up slot EMPTY and read the resulting discard as
    /// the cap at work. The cap forces nothing while a slot is free: that discard destroyed a
    /// version the popover was still offering, and `QueueViewModelTests`'
    /// `testSwitchingToOriginalParksIntoTheFreeSlotRatherThanEvictingTheParkedVersion` now pins the
    /// park into the free slot instead.
    func testUseOriginalDiscardsAnOccupantOnlyWhenBothParkedSlotsAreFull() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        try await env.runToDone()
        let id = try XCTUnwrap(model.jobs.first).id
        // A re-run that retains a variant of its own fills BOTH slots: its loser takes the
        // runner-up, and the version it replaces parks as the previous.
        env.stub.script = { _, _ in
            .init(outcome: .compressedHeavy(before: 9_000, after: 2_000, runnerUpBytes: 1_500),
                  shippedBytes: 2_000, runnerUpBytes: 1_500)
        }
        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }
        let occupant = try XCTUnwrap(model.versions(for: try job(model, id))?.previous?.url)
        let retained = try XCTUnwrap(model.versions(for: try job(model, id))?.runnerUp?.url)
        XCTAssertTrue(exists(occupant))

        await model.useCard(.originalReference, for: try job(model, id))

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .original)
        XCTAssertEqual(row.previous?.bytes, 2_000, "the version they had is the one parked")
        XCTAssertNotEqual(row.previous?.url, occupant)
        XCTAssertFalse(exists(occupant), "the superseded park is discarded, never accumulated")
        XCTAssertEqual(row.runnerUp?.url, retained, "the other slot's version is not touched")
        XCTAssertTrue(exists(retained))
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

        // R12 requires the note to actually reach the row (the versions popover was its only
        // reader before this fix, and it is gone) — the row's own meta line is the surface.
        let message = try XCTUnwrap(model.recompressErrors[id])
        let descriptor = QueueRowsView.describe(job: try job(model, id), model: model, state: .finished)
        XCTAssertEqual(descriptor.metaAccent?.text, message, "the row must show the failure, not swallow it")
        XCTAssertEqual(descriptor.metaAccent?.colour, Theme.Colors.danger)
    }

    // MARK: the scan-rebuild consent queue (spec §7 Scan choice)

    /// The engine's gs-won shape: the plain gs output ships, the VALID hybrid that LOST the size
    /// gate is retained beside it (spec §5's R7 reversal). `HeavyEnv`'s default is the opposite
    /// pairing, and on it "keep the rebuilt one" is already true before the view model does
    /// anything — so the two tests that must not be tautologies build this one instead.
    private static func gsWonPair(before: Int = 9_000) -> StubCompressEngine.Response {
        .init(outcome: RowOutcome(originalBytes: before, finalBytes: HeavyEnv.normalBytes,
                                  compress: .compressed(before: before,
                                                        after: HeavyEnv.normalBytes),
                                  shippedVariant: .plain,
                                  runnerUp: RetainedVariant(kind: .mrc,
                                                            bytes: HeavyEnv.heavyBytes,
                                                            searchable: false)),
              shippedBytes: HeavyEnv.normalBytes, runnerUpBytes: HeavyEnv.heavyBytes)
    }

    /// One sheet at a time, oldest first, and resolving one takes exactly that one out of the
    /// queue. The tail also covers the lifecycle: a consent about a row that has left the queue
    /// would ask the user to choose between two files the app has just discarded.
    func testConsentQueuedFIFOAndResolved() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let first = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, first) != nil }
        let second = try await env.addRow(try Fixtures.blankPDF())
        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, second) != nil }

        XCTAssertEqual(model.pendingConsents, [first, second],
                       "FIFO across files — the sheet surfaces the head")

        await model.resolveConsent(first, keepRebuilt: true)

        XCTAssertEqual(model.pendingConsents, [second],
                       "the answered row leaves; the rest keep their order")
        XCTAssertEqual(model.versions(for: try job(model, first))?.shipped?.variant, .mrc,
                       "keeping the rebuilt one it already shipped moves nothing")

        model.remove(try job(model, second))

        XCTAssertTrue(model.pendingConsents.isEmpty,
                      "a consent must not outlive the row it is about")

        // `⊗ Clear` is the OTHER lifecycle path and a different line of code: `remove` purges
        // explicitly because `queue.remove` is a no-op on a finished row, while Clear goes through
        // the queue's republish and the live-rows sweep.
        let third = try await env.addRow(try Fixtures.blankPDF())
        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, third) != nil }
        XCTAssertEqual(model.pendingConsents, [third])

        model.clearFinished()

        XCTAssertTrue(model.pendingConsents.isEmpty, "⊗ Clear takes the row's consent with it")
    }

    /// The sheet arrives as each file's delivery completes, mid-run (spec §7) — not at the end of
    /// the batch. The first row reads no text, so it finishes while the second is still inside its
    /// OCR leg, held on the stub's gate.
    func testConsentAppearsMidRun() async throws {
        let (env, ocr) = try env(added)
        let model = env.model
        let gate = Gate()
        ocr.gate = gate
        let first = try await env.addRow()
        let second = try await env.addRow(try Fixtures.blankPDF())
        model.setOverride(RowOverride(ocr: false), for: first)

        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, first) != nil }

        XCTAssertEqual(model.pendingConsents, [first],
                       "the first file's choice is asked while the batch is still running")
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(outcome(model, second), "the later row is still held in its OCR leg")

        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(model.pendingConsents, [first, second],
                       "the second joins the queue behind the first")
    }

    /// The DESCRIPTOR fires the sheet, never the gate winner: with the R7 asymmetry removed, a row
    /// whose hybrid lost the size gate has both variants on disk and exactly the same question to
    /// ask (spec §5/§7). Keying this on "the hybrid shipped" is the asymmetry creeping back.
    func testConsentFiresRegardlessOfGateWinner() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in Self.gsWonPair() }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, id) != nil }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .plain, "sanity: the gs output won the gate")
        XCTAssertEqual(row.runnerUp?.variant, .mrc, "the hybrid that LOST is still retained")
        XCTAssertEqual(model.pendingConsents, [id],
                       "the retained pair asks the question whichever variant shipped")
    }

    /// The toggle's promise (spec §7): no sheet, and the REBUILT variant is the one they end up
    /// with — here it has to be switched in, because the gs output won the provisional gate. The
    /// undo leg is the point of the second half: the demoted variant stays parked, so the versions
    /// capsule can still put it back.
    func testRebuildWithoutAskingSkipsConsentAndKeepsRebuilt() async throws {
        let suite = "toolbox.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let env = try HeavyEnv(defaults: defaults)
        let model = env.model
        model.rebuildWithoutAsking = true
        env.stub.script = { _, _ in Self.gsWonPair() }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, id) != nil }
        // The silent keep-rebuilt switch is a switch like any other, so it lands after the ingest
        // that triggered it rather than inside it.
        try await waitUntil(timeout: 5) {
            model.jobs.first.flatMap { model.versions(for: $0)?.shipped?.variant } == .mrc
        }

        XCTAssertTrue(model.pendingConsents.isEmpty, "the preference answers the question")
        XCTAssertTrue(defaults.bool(forKey: "rebuildScansWithoutAsking"),
                      "the promise outlives the session that made it — renaming the key orphans it")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), HeavyEnv.heavyBytes,
                       "the rebuilt BYTES are what they have, not merely the label")
        XCTAssertEqual(row.runnerUp?.variant, .plain, "the demoted gs output stays as the undo")
        XCTAssertEqual(row.runnerUp?.bytes, HeavyEnv.normalBytes)
        XCTAssertTrue(exists(row.runnerUp?.url), "the capsule's offer is backed by a real file")
    }

    /// "Keep photographs" is an instant switch between two files already on disk — and it moves the
    /// searchability flags with the bytes, because it goes through `swapShipped` rather than
    /// exchanging the two descriptions by hand. The runner-up's append fails here precisely so the
    /// flags are ASYMMETRIC: a bespoke swap would leave the row claiming the wrong file reads.
    func testConsentKeepPhotographsSwapsInstantly() async throws {
        let (env, ocr) = try env(added)
        let model = env.model
        ocr.throwOnAppendCall = 2       // the delivered file carries the layer; the runner-up cannot
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, id) != nil }

        XCTAssertEqual(model.pendingConsents, [id])
        let before = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(before.searchableByCard[.shipped], true)
        XCTAssertEqual(before.searchableByCard[.runnerUp], false)

        await model.resolveConsent(id, keepRebuilt: false)

        XCTAssertTrue(model.pendingConsents.isEmpty)
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .plain, "the photographs are what they now have")
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.normalBytes)
        XCTAssertEqual(TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)), HeavyEnv.normalBytes,
                       "the bytes moved, not just the label")
        XCTAssertEqual(row.searchableByCard[.shipped], false,
                       "the flags travel with the bytes")
        XCTAssertEqual(row.searchableByCard[.runnerUp], true)
        XCTAssertEqual(row.runnerUp?.variant, .mrc, "the rebuilt one stays parked as the undo")
    }

    // MARK: the re-run paths (spec §6.4 "re-runs re-apply OCR", §7 per-file settings)

    /// A quality re-run regenerates the delivered file, so the layer has to be re-applied to it —
    /// asserted on the BYTES (the real `OCREngine`), never on the row's claim: a re-run that only
    /// relabelled would satisfy an append-count assertion while handing the user a file that no
    /// longer reads.
    func testChangeQualityReRunReAppliesOCR() async throws {
        let env = try HeavyEnv()                        // the real `OCREngine`
        let model = env.model
        model.ocrOn = true
        model.preset = .balanced
        let input = try Fixtures.textImagePDF()
        let payload = try TestSupport.tinyValidPDF(matching: input)
        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: payload.count),
                  shippedBytes: nil, runnerUpBytes: nil, shippedPayload: payload)
        }
        let id = try await env.addRow(input)

        model.compress()
        try await waitUntil(timeout: 120) { !model.isRunning }
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(try PDFService().pageHasText(delivered, index: 0),
                      "sanity: the first run's layer landed")

        // The re-run's fresh artefact carries no layer of its own — only this leg can put one back.
        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try job(model, id)), .armed(.smallestSize))
        model.compress()
        try await waitUntil(timeout: 120) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.preset, .smallestSize, "sanity: the re-run committed")
        XCTAssertTrue(try PDFService().pageHasText(try XCTUnwrap(row.shipped?.url), index: 0),
                      "the regenerated file must carry the layer, not merely the row's claim")
        XCTAssertEqual(row.searchableByCard[.shipped], true)
        XCTAssertEqual(row.shipped?.bytes, TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)),
                       "the commit re-stats the regenerated file AFTER the append")
    }

    /// A rebuild opt-out belongs to the ROW, not to the batch that first ran it (spec §7): both
    /// non-batch call sites must carry it to the engine, or a row the user excluded from the
    /// rebuild is silently rebuilt the moment they change quality or switch versions.
    func testReRunHonoursRowRebuildOptOut() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(env.stub.rebuildScans, [nil], "sanity: the first run carried no override")

        model.setOverride(RowOverride(rebuildScan: false), for: id)
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(env.stub.rebuildScans, [nil, false],
                       "the quality re-run carries the row's own opt-out")

        // The other non-batch call site: a vanished runner-up regenerates the pair.
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        try FileManager.default.removeItem(at: try XCTUnwrap(row.runnerUp?.url))
        await model.useVersion(.runnerUp, for: try job(model, id))
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(id) }

        XCTAssertEqual(env.stub.rebuildScans, [nil, false, false],
                       "the switch re-run carries it too")
    }

    /// The switch re-run maps the regenerated pair from the DESCRIPTOR — `shippedVariant` plus the
    /// runner-up's kind — never from "the hybrid must have won" (spec §5's R7 reversal). The
    /// gs-shipped direction is the one the old keying dropped: it left the row silently
    /// unswitched, with a freshly regenerated runner-up beside a stale winner.
    func testRerunForSwitchMapsVariantsFromDescriptorKind() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in Self.gsWonPair() }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { self.outcome(model, id) != nil }
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.variant, .plain, "sanity: the gs output won the gate")
        let shippedURL = try XCTUnwrap(row.shipped?.url)
        let runnerUpURL = try XCTUnwrap(row.runnerUp?.url)
        try FileManager.default.removeItem(at: runnerUpURL)  // the retained hybrid leaves the cache

        await model.useVersion(.runnerUp, for: try job(model, id))
        try await waitUntil(timeout: 5) { !model.switchesInFlight.contains(id) }

        let settled = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(settled.shipped?.variant, .mrc, "the requested hybrid is what they now have")
        XCTAssertEqual(settled.shipped?.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(settled.runnerUp?.variant, .plain, "the gs output takes the parked slot")
        XCTAssertEqual(try Data(contentsOf: shippedURL),
                       Data(repeating: 0x4E, count: HeavyEnv.heavyBytes),
                       "the shipped file holds the regenerated hybrid's BYTES, not just its label")
        XCTAssertEqual(try Data(contentsOf: runnerUpURL),
                       Data(repeating: 0x48, count: HeavyEnv.normalBytes))
        XCTAssertNil(model.recompressErrors[id], "the switch landed — there is nothing to report")
        XCTAssertEqual(model.pendingConsents, [id],
                       "a switch re-run asks nothing new: the user has just named the variant")
    }

    /// The demoted file's claim travels with it into the `.previous` slot — never recomputed —
    /// while the file that replaced it is labelled from THIS re-run's own append. The two differ
    /// here on purpose: a carried-over flag and a recomputed one are indistinguishable when they
    /// agree.
    func testPreviousSlotCarriesSearchabilityFlag() async throws {
        let (env, ocr) = try env(added)
        let model = env.model
        model.preset = .balanced
        // No runner-up on either run, so the appends are the delivered file's alone and the
        // failing call below is unambiguous.
        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: 700),
                  shippedBytes: 700, runnerUpBytes: nil)
        }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.versions(for: try job(model, id))?.searchableByCard[.shipped], true)

        ocr.throwOnAppendCall = 2       // the re-run's own append; the first run's already landed
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.previous], true,
                       "the demoted file still reads — its own claim moves into the slot with it")
        XCTAssertEqual(row.searchableByCard[.shipped], false,
                       "the file that replaced it could not carry the layer, and says so")
    }

    /// Acceptance criterion 3 has no exemption on the re-run path — and the failure is PER FILE:
    /// the runner-up regenerated beside the winner carries its own append's result, so a blanket
    /// per-row flag would be a lie in one direction or the other.
    func testReRunAppendFailureMarksShippedUnsearchable() async throws {
        let (env, ocr) = try env(added)
        let model = env.model
        model.preset = .balanced
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        // Run 1 appends to the delivered file (1) then the runner-up (2); the re-run repeats that
        // order, so its winner is call 3.
        XCTAssertEqual(ocr.appendCallCount, 2)
        ocr.throwOnAppendCall = 3

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false)
        XCTAssertEqual(row.searchableByCard[.runnerUp], true,
                       "the sibling variant's append succeeded — the failure is that file's alone")
        XCTAssertEqual(row.shipped?.bytes, TestSupport.fileSize(try XCTUnwrap(row.shipped?.url)),
                       "a winner that carries no layer still records what it actually weighs")
    }

    /// The untouched original is NEVER appended to (spec §6.4), and that binds the re-run path
    /// too: a row whose gs candidate bloated past the input parks the input itself, so an append
    /// there would modify the one file the app promises to leave alone. Its card is labelled from
    /// the OUTCOME instead — and the consent sheet stays away from a pair that has no "just
    /// lighter" variant to offer (spec §6.3, the `.original`-park exclusion).
    func testReRunNeverAppendsToAParkedOriginal() async throws {
        let (env, ocr) = try env(added)
        let model = env.model
        model.preset = .balanced
        ocr.growthBytes = 10        // an append is then visible in the file's own size
        // `runnerUpBytes == before` is the R6/R7 marker: the gs candidate bloated past the input,
        // so what got parked is the untouched input.
        env.stub.script = { _, _ in
            .init(outcome: .compressedHeavy(before: 9_000, after: 1_200, runnerUpBytes: 9_000),
                  shippedBytes: 1_200, runnerUpBytes: 9_000)
        }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.versions(for: try job(model, id))?.runnerUp?.variant, .original,
                       "sanity: the untouched input is what was parked")
        let appendsBefore = ocr.appendCallCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        let parked = try XCTUnwrap(row.runnerUp?.url)
        XCTAssertEqual(row.runnerUp?.variant, .original)
        XCTAssertEqual(ocr.appendCallCount, appendsBefore + 1,
                       "the re-run appends to its winner ONLY")
        XCTAssertFalse(ocr.appendTargets.contains(parked),
                       "the parked original was never handed to the writer")
        XCTAssertEqual(TestSupport.fileSize(parked), 9_000,
                       "byte-for-byte the input — an append would have grown it")
        XCTAssertEqual(row.searchableByCard[.runnerUp], false,
                       "outcome-keyed: this read returned .added, never .alreadySearchable")
        XCTAssertTrue(model.pendingConsents.isEmpty,
                      "an original park is not the pair the sheet is about")
    }

    /// The WinAnsi guard is the batch leg's own, shared rather than reimplemented: a document whose
    /// every recognised run would land as `?` gets NO layer on the re-run path either. Both
    /// regenerated files say so instead of carrying a page of question marks that would pass every
    /// validation while misrepresenting the user's text.
    func testReRunSkipsTheAppendWhenTheLayerWouldBeLost() async throws {
        let (env, ocr) = try env(allLossy)
        let model = env.model
        model.preset = .balanced
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(ocr.appendCallCount, 0, "sanity: the batch leg declined the append")

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(ocr.appendCallCount, 0, "the re-run declines it on the same evidence")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.searchableByCard[.shipped], false)
        XCTAssertEqual(row.searchableByCard[.runnerUp], false)
    }

    /// A quality re-run builds a NEW pair of scan variants, and the preset the user picked says
    /// nothing about which of them they want — the two axes are orthogonal, so the question is
    /// asked again (spec §7: shown whenever both variants exist, as each delivery completes). The
    /// two tails pin the rest of that rule: a row already waiting for its answer is queued ONCE,
    /// and a re-run that keeps no second variant WITHDRAWS the question rather than leaving a
    /// sheet offering a choice between two files when only one exists.
    func testReRunOfARebuiltScanAsksTheConsentQuestionAgain() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.pendingConsents, [id])
        await model.resolveConsent(id, keepRebuilt: true)
        XCTAssertTrue(model.pendingConsents.isEmpty)

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.pendingConsents, [id],
                       "the re-run's own pair is a fresh choice about the page, not the quality")

        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.pendingConsents, [id],
                       "a row already waiting for its answer is not asked twice")

        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: 700),
                  shippedBytes: 700, runnerUpBytes: nil)
        }
        model.preset = .balanced
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertTrue(model.pendingConsents.isEmpty,
                      "this run kept no second variant — there is no longer a choice to put")
    }

    /// The armed no-gain row that was rescued by its OCR leg already holds a real file at the
    /// `-ocr.pdf` name it reserved, so the re-run's landing step meets an OCCUPIED destination —
    /// R11 pins the re-run to the row's existing result path (spec §6.5). Moving onto it throws,
    /// which the generic catch would turn into "Recompress failed" while the fresh result is
    /// discarded.
    func testReRunOverAnOCROnlyDeliveryReplacesItInPlace() async throws {
        let (env, _) = try env(added)
        let model = env.model
        model.preset = .balanced
        env.stub.script = { call, _ in
            call == 1
                ? .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
                : .init(outcome: .compressed(before: 9_000, after: 700),
                        shippedBytes: 700, runnerUpBytes: nil)
        }
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let delivered = try XCTUnwrap(try job(model, id).resultURL)
        XCTAssertTrue(delivered.lastPathComponent.hasSuffix("-ocr.pdf"),
                      "sanity: a delivery carrying no compression ships under the -ocr name")
        XCTAssertNil(model.versions(for: try job(model, id))?.shipped,
                     "sanity: a no-gain row records no shipped version")

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertNil(model.recompressErrors[id], "the re-run landed — there is nothing to report")
        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertEqual(row.shipped?.url, delivered, "R11: the row's own existing result path")
        XCTAssertEqual(TestSupport.fileSize(delivered), row.shipped?.bytes,
                       "the file on disk is the one the row describes")
        XCTAssertEqual(row.searchableByCard[.shipped], true,
                       "the re-run re-applied the layer to what it regenerated")
    }

    /// The flags describe the BYTES. A re-run with the read verb off regenerates the delivered
    /// file, so the claim the OLD file earned cannot ride onto it — and "not searchable" is no
    /// better, because a born-digital input keeps its own text layer straight through the engine.
    /// No OCR leg means no recorded outcome, so the row claims NOTHING (spec §6.4).
    func testReRunWithOCROffDropsTheStaleSearchabilityClaim() async throws {
        let (env, _) = try env(added)
        let model = env.model
        model.preset = .balanced
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.versions(for: try job(model, id))?.searchableByCard[.shipped], true)

        model.ocrOn = false
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try job(model, id)))
        XCTAssertNil(row.searchableByCard[.shipped],
                     "no read ran over the new bytes, so the row makes no claim about them")
        XCTAssertNil(row.searchableByCard[.runnerUp])
        XCTAssertEqual(row.searchableByCard[.previous], true,
                       "the demoted file's own claim is still true of it")
    }

    // MARK: recent-batches history (spec §6.9, F6)

    /// A plain single-row batch records one history entry with the batch's own facts.
    func testBatchEndRecordsHistory() async throws {
        let env = try HeavyEnv()                        // compress only, no OCR verb
        let model = env.model
        _ = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(env.history.batches.count, 1)
        let recorded = try XCTUnwrap(env.history.batches.first)
        XCTAssertEqual(recorded.fileCount, 1)
        XCTAssertTrue(recorded.compressOn)
        XCTAssertFalse(recorded.ocrOn)
        XCTAssertEqual(recorded.presetTitle, CompressPreset.balanced.title)
        XCTAssertEqual(recorded.savedBytes, 9_000 - HeavyEnv.heavyBytes)
        XCTAssertEqual(recorded.searchableCount, 0, "no OCR leg ran")
        XCTAssertFalse(recorded.partial)
        XCTAssertFalse(recorded.problem)
        XCTAssertFalse(recorded.cancelled)
        XCTAssertEqual(env.history.lifetimeSavedBytes, recorded.savedBytes)
    }

    /// A row whose OCR append grows the delivered file past the original (`RowOutcome.grew`,
    /// spec §6.3) contributes ZERO to the batch's `savedBytes` — never a negative number, which
    /// would drag `lifetimeSavedBytes` — a persisted, monotonic "saved since you installed
    /// Toolbox" counter — DOWN.
    func testGrownRowContributesZeroNeverNegativeToSavedBytes() async throws {
        let (env, ocr) = try env(added)
        ocr.growthBytes = 500
        env.stub.script = { _, _ in
            .init(outcome: .compressed(before: 9_000, after: 8_990), shippedBytes: 8_990,
                 runnerUpBytes: nil)
        }
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertTrue(try XCTUnwrap(outcome(model, id)).grew, "the append pushed it past the original")
        let recorded = try XCTUnwrap(env.history.batches.first)
        XCTAssertEqual(recorded.savedBytes, 0, "a grown row must never contribute a negative saving")
        XCTAssertEqual(env.history.lifetimeSavedBytes, 0, "the lifetime counter must never go negative")
    }

    /// Cancelled between the legs (as `testCancelBetweenLegsBanksCompressed`): the compress
    /// delivery is atomic and complete, so it is kept and banked — the batch must still be
    /// recorded, `cancelled` and degraded-so-`partial` both true.
    func testCancelledBatchWithBankedFileRecordsEntry() async throws {
        let (env, ocr) = try env(added)
        let gate = Gate()
        env.stub.gate = gate
        let model = env.model
        _ = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }
        XCTAssertEqual(ocr.recogniseCallCount, 0)

        XCTAssertEqual(env.history.batches.count, 1)
        let recorded = try XCTUnwrap(env.history.batches.first)
        XCTAssertTrue(recorded.cancelled)
        XCTAssertTrue(recorded.partial, "the banked row is degraded — cancelled before reading")
        XCTAssertFalse(recorded.problem)
        XCTAssertEqual(recorded.savedBytes, 9_000 - HeavyEnv.heavyBytes,
                       "the compress delivery completed before the cancel landed")
    }

    /// The same boundary on a row that delivered NOTHING (as
    /// `testCancelBetweenLegsRequeuesARowThatDeliveredNothing`): the row goes back to `.queued`,
    /// nothing was ever banked, and a cancelled batch with nothing banked records no entry at all.
    func testCancelledEmptyBatchRecordsNothing() async throws {
        let (env, _) = try env(added)
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let model = env.model
        _ = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertTrue(env.history.batches.isEmpty)
        XCTAssertEqual(env.history.lifetimeSavedBytes, 0)
    }

    /// A rescued row and a noGain+OCR sibling row both deliver `<name>-ocr.pdf` with no
    /// compression artefact behind it — neither contributes to `savedBytes`, and both count
    /// through `searchableCount` (spec §6.5's exclusions, §6.9's "one made searchable"). Run as
    /// two sequential single-row batches on the same env — a rescued row never re-arms
    /// (`recompressState`'s `case nil, .skipped: return .none`), so it cannot interfere with the
    /// second batch's own `runQueuedIDs`.
    func testOCROnlyAndRescuedRowsExcludedFromSavedBytes() async throws {
        let (env, _) = try env(added)
        let model = env.model

        // Batch 1 — the compress-failure rescue.
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        _ = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        // Batch 2 — the noGain + OCR sibling.
        env.stub.throwOnCall = nil
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
        }
        _ = try await env.addRow()
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(env.history.batches.count, 2)
        for recorded in env.history.batches {
            XCTAssertEqual(recorded.savedBytes, 0, "an OCR-only delivery makes no savings claim")
            XCTAssertEqual(recorded.searchableCount, 1, "made searchable, whatever else happened")
        }
        XCTAssertEqual(env.history.lifetimeSavedBytes, 0)
    }

    /// A Change-Quality re-run (all rows armed, none freshly queued) must not record a second
    /// history entry for bytes the first batch already counted — `runQueuedIDs` being empty is
    /// what excludes it (`recordBatchHistory`'s own guard), never a special case here.
    func testRecompressOnlyBatchDoesNotDoubleCountIntoHistory() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }
        XCTAssertEqual(env.history.batches.count, 1)
        let firstSaving = try XCTUnwrap(env.history.batches.first).savedBytes
        XCTAssertEqual(env.history.lifetimeSavedBytes, firstSaving)

        // Recompress the same row at a different preset — an armed-only pass.
        model.preset = .smallestSize
        try await waitUntil(timeout: 5) {
            guard let row = model.jobs.first(where: { $0.id == id }) else { return false }
            return model.recompressState(for: row) != .none
        }
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(env.history.batches.count, 1, "a pure recompress records no new entry")
        XCTAssertEqual(env.history.lifetimeSavedBytes, firstSaving,
                       "the recompress's saving must not be added on top of the first batch's")
    }

    /// A `Compressing` double that fails only the row whose input is `throwFor`, keyed on the
    /// real input URL rather than a call index. `StubCompressEngine.throwOnCall` targets a call
    /// COUNT, which is meaningless once two rows run concurrently (batch width =
    /// `SystemInfo.performanceCoreCount`) — either row could claim call 1. Keying on the URL
    /// instead makes the outcome deterministic regardless of scheduling order.
    private final class URLKeyedCompressEngine: Compressing, @unchecked Sendable {
        let throwFor: URL
        let goodAfterBytes: Int

        init(throwFor: URL, goodAfterBytes: Int) {
            self.throwFor = throwFor
            self.goodAfterBytes = goodAfterBytes
        }

        func compress(_ input: URL, preset: CompressPreset, to output: URL, alternateOutput: URL?,
                     rebuildScan: Bool?, mrcReport: ((MRCDocumentReport) -> Void)?,
                     progress: @escaping (Double) -> Void) async throws -> RowOutcome {
            if input == throwFor { throw CompressError.encrypted }
            try Data(repeating: 0x48, count: goodAfterBytes).write(to: output)
            return .compressed(before: 9_000, after: goodAfterBytes)
        }
    }

    /// F6b: a genuinely locked row (`Fixtures.encryptedPDF`, add-time-detected via the real
    /// `OpenGuard`) alongside a healthy one. `fileCount` counts both, `successCount` only the row
    /// that delivered, `problem` is true, and `failureNote` names the password-locked family —
    /// the handoff's screen-01/11 card copy ("4 of 5 files in Invoices · one was password-locked").
    func testBatchWithLockedRowRecordsSuccessCountAndFailureNote() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("f6b-locked-\(UUID().uuidString)", isDirectory: true)
        let outputFolder = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let history = HistoryStore(directory: tmp.appendingPathComponent("history", isDirectory: true))
        let store = RunnerUpStore(rootOverride: tmp.appendingPathComponent("cache", isDirectory: true))

        let goodInput = try Fixtures.imagePDF()
        let lockedInput = try Fixtures.encryptedPDF()
        let engine = URLKeyedCompressEngine(throwFor: lockedInput, goodAfterBytes: 4_000)
        let model = QueueViewModel(engine: engine, store: store, history: history)
        model.outputFolder = outputFolder

        model.add([goodInput])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.add([lockedInput])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let lockedID = try XCTUnwrap(model.jobs.last?.id)
        // Wait for add-time inspection to land before running, so the locked cause is on record
        // regardless of how fast the batch itself completes.
        try await waitUntil(timeout: 5) { model.inspections[lockedID]?.problem == .locked }

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(history.batches.count, 1)
        let recorded = try XCTUnwrap(history.batches.first)
        XCTAssertEqual(recorded.fileCount, 2)
        XCTAssertEqual(recorded.successCount, 1)
        XCTAssertTrue(recorded.problem)
        XCTAssertEqual(recorded.failureNote, "one was password-locked")
    }
}
