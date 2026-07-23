// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import PDFKit
import XCTest
@testable import PDFToolbox

final class PDFWriterTests: XCTestCase {

    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    // MARK: - Coordinate transform (pure functions PDFWriter owns)

    func testDisplayedSizeSwapsAt90And270() {
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 0), CGSize(width: 612, height: 792))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 180), CGSize(width: 612, height: 792))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 90), CGSize(width: 792, height: 612))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 270), CGSize(width: 792, height: 612))
    }

    func testUserPointInverseRotationConcrete() {
        let p = CGPoint(x: 100, y: 200)
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 0),   CGPoint(x: 100, y: 200))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 90),  CGPoint(x: 412, y: 100))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 180), CGPoint(x: 512, y: 592))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 270), CGPoint(x: 200, y: 692))
    }

    /// The displayed rectangle's corners must map bijectively onto the media rectangle — a
    /// direction-independent proof the rotation maths is a true rotation, not a wrong model.
    func testRotationCornersCoverMediaBox() {
        for rotation in [0, 90, 180, 270] {
            let d = PDFWriter.displayedSize(mediaBox: letter, rotation: rotation)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: d.width, y: 0),
                           CGPoint(x: d.width, y: d.height), CGPoint(x: 0, y: d.height)]
            let mapped = corners.map { PDFWriter.userPoint(displayed: $0, mediaBox: letter, rotation: rotation) }
            let xs = mapped.map(\.x), ys = mapped.map(\.y)
            XCTAssertEqual(xs.min()!, 0, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(xs.max()!, 612, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(ys.min()!, 0, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(ys.max()!, 792, accuracy: 0.01, "rotation \(rotation)")
        }
    }

    func testMediaBoxOriginOffsetApplied() {
        let shifted = CGRect(x: 50, y: 30, width: 612, height: 792)
        assertPoint(PDFWriter.userPoint(displayed: CGPoint(x: 0, y: 0), mediaBox: shifted, rotation: 0),
                    CGPoint(x: 50, y: 30))
    }

    // MARK: - Incremental-update invariants

    func testOriginalBytesAreVerbatimPrefixOfOutput() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "prefix.pdf")
        let before = try Data(contentsOf: input)

        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let after = try Data(contentsOf: output)
        XCTAssertGreaterThan(after.count, before.count, "an incremental update only grows the file")
        XCTAssertEqual(after.prefix(before.count), before,
                       "the original bytes (incl. every image XObject) must be a verbatim prefix")
    }

    func testAppendedTextIsExtractableAndPageCountPreserved() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "extract.pdf")

        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount)
        let text = outDoc.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("HELLO"), "expected the invisible layer to be extractable, got: \(text.debugDescription)")
    }

    /// The output re-opens, page count matches, sample pages render non-blank (image still there).
    func testOutputPassesValidator() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "valid.pdf")
        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])
        XCTAssertTrue(try OutputValidator().validate(input: input, output: output))
    }

    /// End-to-end offset/scale sanity on the un-rotated path: PDFKit must report the first glyph
    /// near the user-space point the transform computed (catches a gross offset or scale error
    /// that mere extractability would miss).
    func testZeroDegreeGlyphLandsAtMappedLocation() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "placed.pdf")
        let box = PositionedText(text: "MARK", boundingBox: CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.04))
        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [box]], geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let doc = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(doc.page(at: 0))
        let expected = PDFWriter.userPoint(displayed: CGPoint(x: 0.2 * 612, y: 0.6 * 792),
                                           mediaBox: letter, rotation: 0)          // (122.4, 475.2)
        let bounds = page.characterBounds(at: 0)
        XCTAssertEqual(bounds.minX, expected.x, accuracy: 40, "glyph X should sit near the mapped origin")
        XCTAssertEqual(bounds.minY, expected.y, accuracy: 60, "glyph Y should sit near the mapped origin")
    }

    /// The whole pipeline runs on a `/Rotate 90` page without corrupting it, and the layer stays
    /// extractable (the transform's rotation maths is proven separately by the pure-function tests).
    func testRotatedPageAppendIsExtractable() throws {
        let base = try Fixtures.imagePDF()
        let rotatedDoc = try XCTUnwrap(PDFDocument(url: base))
        rotatedDoc.page(at: 0)?.rotation = 90
        let rotated = try sibling(of: base, "rotated.pdf")
        XCTAssertTrue(rotatedDoc.write(to: rotated))

        let output = try sibling(of: base, "rotated-ocr.pdf")
        try PDFWriter().appendTextLayer(
            to: rotated, output: output,
            pageText: [0: [PositionedText(text: "SIDEWAYS", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 90)])

        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, 1)
        XCTAssertTrue((outDoc.page(at: 0)?.string ?? "").contains("SIDEWAYS"))
        // The original rotated file is still the verbatim prefix.
        let before = try Data(contentsOf: rotated)
        let after = try Data(contentsOf: output)
        XCTAssertEqual(after.prefix(before.count), before)
    }

    // MARK: - Parser regressions against hostile and merely-unusual input
    //
    // Every fixture below is hand-authored bytes. The CoreGraphics-generated fixtures above are
    // always well-formed, ASCII-clean and LF-terminated, which is exactly why they never caught
    // any of these.

    /// C1: `stream` occurs inside the ordinary font name `BitstreamVeraSans`. A scanner that
    /// accepts the bare substring starts a phantom stream body there, skips to the next real
    /// `endstream`, and loses every object header in between — including the page.
    func testStreamKeywordInsideAWordDoesNotHideLaterObjects() throws {
        let input = try Fixtures.rawPDF([
            Fixtures.rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            Fixtures.rawObject(2, "<< /Type /Pages /Kids [ 3 0 R ] /Count 1 >>"),
            Fixtures.rawObject(3, "<< /Type /Font /Subtype /Type1 /BaseFont /BitstreamVeraSans >>"),
            Fixtures.rawObject(4, "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
                                + "/Contents 5 0 R /Resources << /Font << /F1 3 0 R >> >> >>"),
            Fixtures.rawStream(5, body: Data("0.9 0.9 0.9 rg 72 72 468 648 re f".utf8)),
        ], root: 1, name: "bitstream.pdf")

        let bytes = [UInt8](try Data(contentsOf: input))
        let index = try PDFWriter.indexTopLevelObjects(bytes)
        XCTAssertEqual(Set(index.keys), [1, 2, 3, 4, 5],
                       "the page and content objects sit after the word `Bitstream`")

        let output = try sibling(of: input, "bitstream-ocr.pdf")
        try write(input, to: output)
        XCTAssertEqual(try supersededPageDictCount(of: "/Contents", in: output, objNum: 4), 1)
    }

    /// S22: the stream body carries the bytes `endstream` followed by a phantom `4 0 obj`.
    /// Delimiting the body by searching for `endstream` ends the skip early, and the planted
    /// object — deliberately placed *after* the genuine object 4, so "later offset wins" — takes
    /// its place.
    func testPlantedObjectInsideAStreamBodyDoesNotOverrideTheRealOne() throws {
        var payload = Data("binary-ish payload ".utf8)
        payload.append(Data("endstream\n4 0 obj\n<< /Type /Page /Attacker true >>\nendobj\n".utf8))
        payload.append(Data("trailing".utf8))

        let input = try Fixtures.rawPDF([
            Fixtures.rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            Fixtures.rawObject(2, "<< /Type /Pages /Kids [ 4 0 R ] /Count 1 >>"),
            Fixtures.rawStream(3, body: Data("0.9 0.9 0.9 rg 72 72 468 648 re f".utf8)),
            Fixtures.rawObject(4, "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
                                + "/Contents 3 0 R /Resources << >> >>"),
            Fixtures.rawStream(5, body: payload),
        ], root: 1, name: "planted.pdf")

        let bytes = [UInt8](try Data(contentsOf: input))
        let index = try fullIndex(bytes)
        let page = try XCTUnwrap(PDFWriter.objectDict(bytes, objects: index, objNum: 4))
        let text = String(decoding: page.bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("/MediaBox"), "object 4 must still be the real page, got: \(text)")
        XCTAssertFalse(text.contains("/Attacker"), "an object planted inside a stream body must not win")
    }

    /// S5: a `>>` inside a legal literal string truncated the extracted dictionary, and the
    /// truncated fragment was then appended to the user's document as the superseding page.
    func testAngleBracketsInsideAStringDoNotTruncateThePageDict() throws {
        let input = try Fixtures.rawOnePagePDF(
            pageDict: "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
                    + "/Title (chapter >> appendix) /Contents 4 0 R /Resources << >> >>",
            name: "string-close.pdf")
        let output = try sibling(of: input, "string-close-ocr.pdf")
        try write(input, to: output)

        let dict = try supersededPageDict(in: output, objNum: 3)
        XCTAssertTrue(dict.contains("(chapter >> appendix)"), "the string survived intact: \(dict)")
        XCTAssertEqual(dict.components(separatedBy: "/Contents").count - 1, 1)
        XCTAssertNotNil(PDFDocument(url: output))
    }

    /// S5, the other direction: a `<<` inside a string raised the nesting depth, `/Contents` was
    /// never matched, and a *second* `/Contents` key was inserted — an invalid dictionary whose
    /// reading is implementation-defined (the page can render blank).
    func testOpeningBracketsInsideAStringDoNotHideContents() throws {
        let input = try Fixtures.rawOnePagePDF(
            pageDict: "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
                    + "/Title (see << here) /Contents 4 0 R /Resources << >> >>",
            name: "string-open.pdf")
        let output = try sibling(of: input, "string-open-ocr.pdf")
        try write(input, to: output)

        let dict = try supersededPageDict(in: output, objNum: 3)
        XCTAssertEqual(dict.components(separatedBy: "/Contents").count - 1, 1,
                       "exactly one /Contents — a duplicate key is invalid PDF: \(dict)")
    }

    /// M7 / S6: with CRLF between the key and its value, a `Character`-based scan sees one
    /// grapheme cluster that is neither CR nor LF, misses `/Contents` entirely, and writes a
    /// duplicate key.
    func testCRLFSeparatedKeyAndValueDoesNotDuplicateContents() throws {
        let input = try Fixtures.rawOnePagePDF(
            pageDict: "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ]\r\n"
                    + "/Contents\r\n4 0 R /Resources << >> >>",
            name: "crlf.pdf", eol: "\r\n")
        let output = try sibling(of: input, "crlf-ocr.pdf")
        try write(input, to: output)

        let dict = try supersededPageDict(in: output, objNum: 3)
        XCTAssertEqual(dict.components(separatedBy: "/Contents").count - 1, 1,
                       "exactly one /Contents: \(dict)")
        XCTAssertTrue(dict.contains("4 0 R"), "the original content ref must be kept: \(dict)")
        XCTAssertNotNil(PDFDocument(url: output))
    }

    /// M5: an object whose value is not a dictionary must report *no* dictionary. Searching
    /// forward for `<<` without bounding it at `endobj` returns the next object's dictionary,
    /// silently attributed to this object number.
    func testNonDictionaryObjectDoesNotBorrowItsNeighboursDictionary() throws {
        let input = try Fixtures.rawPDF([
            Fixtures.rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            Fixtures.rawObject(2, "<< /Type /Pages /Kids [ 3 0 R ] /Count 1 >>"),
            Fixtures.rawObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
                                + "/Contents 5 0 R /Resources << >> >>"),
            Fixtures.rawObject(4, "[ 1 2 3 ]"),
            Fixtures.rawStream(5, body: Data("0.9 0.9 0.9 rg 72 72 468 648 re f".utf8)),
        ], root: 1, name: "non-dict.pdf")

        let bytes = [UInt8](try Data(contentsOf: input))
        let index = try fullIndex(bytes)
        XCTAssertNotNil(index.topLevel[4], "the array object is still indexed")
        XCTAssertNil(PDFWriter.objectDict(bytes, objects: index, objNum: 4),
                     "an array object has no dictionary — borrowing object 5's is the defect")
    }

    /// S4: `9223372036854775807 0 obj` parsed to `Int.max`, and the allocator's `+= 1` trapped,
    /// aborting the process and every other job in the batch. Reaching the end of this test at
    /// all is the assertion.
    func testImplausibleObjectNumberDoesNotCrashTheProcess() throws {
        let base = try Fixtures.rawOnePagePDF(pageDict: Fixtures.plainPageDict, name: "huge-obj.pdf")
        var data = try Data(contentsOf: base)
        data.append(Data("\n9223372036854775807 0 obj\n<< /Type /Bomb >>\nendobj\n".utf8))
        let input = try sibling(of: base, "huge-obj-armed.pdf")
        try data.write(to: input)

        let output = try sibling(of: base, "huge-obj-ocr.pdf")
        try write(input, to: output)                                  // must not trap
        XCTAssertNotNil(PDFDocument(url: output))
    }

    /// S23: a page tree that is a linear chain of `/Pages` nodes is valid PDF and a few megabytes
    /// long; recursing it once per level overflows the stack and kills the app. The walk is now
    /// iterative and depth-bounded, so an absurd chain is refused rather than fatal.
    func testAbsurdlyDeepPageTreeIsRefusedNotFatal() throws {
        let depth = PDFWriter.maxPageTreeDepth + 40
        var objects: [(num: Int, body: Data)] = [Fixtures.rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>")]
        for n in 2..<(2 + depth) {
            objects.append(Fixtures.rawObject(n, "<< /Type /Pages /Kids [ \(n + 1) 0 R ] /Count 1 >>"))
        }
        let leaf = 2 + depth
        objects.append(Fixtures.rawObject(leaf, "<< /Type /Page /Parent \(leaf - 1) 0 R "
                                              + "/MediaBox [ 0 0 612 792 ] /Resources << >> >>"))
        let input = try Fixtures.rawPDF(objects, root: 1, name: "deep-tree.pdf")

        let bytes = [UInt8](try Data(contentsOf: input))
        let index = try fullIndex(bytes)
        XCTAssertThrowsError(try PDFWriter.orderedPageObjects(bytes, objects: index, root: (num: 1, gen: 0))) {
            XCTAssertEqual($0 as? PDFWriterError, .malformedPDF)
        }
    }

    /// Page order must follow the `/Kids` arrays, depth first — the iterative walk has to
    /// reproduce exactly what the recursive one did.
    func testPageOrderFollowsTheKidsTree() throws {
        let input = try Fixtures.rawPDF([
            Fixtures.rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            Fixtures.rawObject(2, "<< /Type /Pages /Kids [ 3 0 R 6 0 R ] /Count 3 >>"),
            Fixtures.rawObject(3, "<< /Type /Pages /Parent 2 0 R /Kids [ 4 0 R 5 0 R ] /Count 2 >>"),
            Fixtures.rawObject(4, "<< /Type /Page /Parent 3 0 R /MediaBox [ 0 0 612 792 ] /Resources << >> >>"),
            Fixtures.rawObject(5, "<< /Type /Page /Parent 3 0 R /MediaBox [ 0 0 612 792 ] /Resources << >> >>"),
            Fixtures.rawObject(6, "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] /Resources << >> >>"),
        ], root: 1, name: "page-order.pdf")

        let bytes = [UInt8](try Data(contentsOf: input))
        let index = try fullIndex(bytes)
        XCTAssertEqual(try PDFWriter.orderedPageObjects(bytes, objects: index, root: (num: 1, gen: 0)),
                       [4, 5, 6])
    }

    // MARK: - Compressed object streams

    /// The fixture must genuinely be the layout under test before any of this means anything:
    /// no top-level `1 0 obj`, and PDFKit opens it as a one-page document.
    func testObjectStreamFixtureIsTheLayoutUnderTest() throws {
        let input = try Fixtures.objectStreamPDF()
        let raw = try Data(contentsOf: input)
        XCTAssertNil(String(decoding: raw, as: UTF8.self).range(of: "1 0 obj"),
                     "the catalog must be packed, not top-level")
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: input)).pageCount, 1)

        let bytes = [UInt8](raw)
        let topLevel = try PDFWriter.indexTopLevelObjects(bytes)
        XCTAssertEqual(Set(topLevel.keys), [4, 5, 6], "only the three streams are top-level")

        let packed = PDFWriter.indexObjectStreams(bytes, topLevel: topLevel)
        XCTAssertEqual(Set(packed.keys), [1, 2, 3], "the catalog, page tree and page are packed")
        XCTAssertTrue(String(decoding: packed[3]!, as: UTF8.self).contains("/MediaBox"))
    }

    /// The feature: a document whose page lives in an object stream used to be refused outright
    /// with `.unsupportedStructure`. It must now resolve, OCR, and stay readable.
    func testPackedPageIsFoundAndSuperseded() throws {
        let input = try Fixtures.objectStreamPDF()
        let bytes = [UInt8](try Data(contentsOf: input))
        let topLevel = try PDFWriter.indexTopLevelObjects(bytes)
        let index = PDFWriter.ObjectIndex(topLevel: topLevel,
                                          packed: PDFWriter.indexObjectStreams(bytes, topLevel: topLevel))

        let root = try PDFWriter.findRoot(bytes, objects: index)
        XCTAssertEqual(root.num, 1)
        XCTAssertEqual(try PDFWriter.orderedPageObjects(bytes, objects: index, root: root), [3])

        let output = try sibling(of: input, "objstm-ocr.pdf")
        try write(input, to: output)

        // The superseding object 3 is an ordinary uncompressed top-level object — no need to
        // rewrite or re-compress the object stream itself.
        let dict = try supersededPageDict(in: output, objNum: 3)
        XCTAssertTrue(dict.contains("/MediaBox"), "the packed dictionary was carried over: \(dict)")
        XCTAssertEqual(dict.components(separatedBy: "/Contents").count - 1, 1)
        XCTAssertTrue(dict.contains("/PDFTBox"), "our font resource was added: \(dict)")
    }

    /// End to end, and the check the whole design rests on: a classic xref section appended to a
    /// cross-reference-stream file, with `/Prev` pointing at that stream, must still be readable —
    /// and the original bytes must remain the verbatim prefix.
    func testObjectStreamDocumentSurvivesTheAppendAndStaysReadable() throws {
        let input = try Fixtures.objectStreamPDF()
        let output = try sibling(of: input, "objstm-readable.pdf")
        let before = try Data(contentsOf: input)
        try write(input, to: output)

        let after = try Data(contentsOf: output)
        XCTAssertEqual(after.prefix(before.count), before, "incremental update: verbatim prefix")

        let doc = try XCTUnwrap(PDFDocument(url: output), "the appended document must still open")
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").contains("HELLO"),
                      "the OCR layer must be extractable, got: "
                      + (doc.page(at: 0)?.string ?? "").debugDescription)

        // The same gates the real pipeline applies before an output is ever placed.
        XCTAssertTrue(try OutputValidator().validate(input: input, output: output))
        XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: input, in: output))
    }

    /// The appended section must match the file's existing cross-reference form — a stream here,
    /// a classic table for a classic file.
    func testCrossReferenceFormMatchesTheInput() throws {
        let stream = try Fixtures.objectStreamPDF(name: "form-stream.pdf")
        let streamOut = try sibling(of: stream, "form-stream-ocr.pdf")
        try write(stream, to: streamOut)
        let appendedToStream = try Data(contentsOf: streamOut).dropFirst(try Data(contentsOf: stream).count)
        XCTAssertNotNil(String(decoding: appendedToStream, as: UTF8.self).range(of: "/Type /XRef"))

        let classic = try Fixtures.rawOnePagePDF(pageDict: Fixtures.plainPageDict, name: "form-classic.pdf")
        let classicOut = try sibling(of: classic, "form-classic-ocr.pdf")
        try write(classic, to: classicOut)
        let appendedToClassic = try Data(contentsOf: classicOut).dropFirst(try Data(contentsOf: classic).count)
        let text = String(decoding: appendedToClassic, as: UTF8.self)
        XCTAssertNotNil(text.range(of: "\nxref\n"))
        XCTAssertNotNil(text.range(of: "trailer"))
    }

    /// An object stream's `/Length` may be an indirect reference. If it is not resolved, the
    /// extent falls back to hunting for `endstream` inside *compressed* bytes that can perfectly
    /// well contain those nine bytes — truncating the payload and losing the packed objects.
    func testIndirectLengthOnAnObjectStreamIsResolved() throws {
        let input = try Fixtures.objectStreamPDF(name: "objstm-indirect.pdf", indirectLength: true)
        let bytes = [UInt8](try Data(contentsOf: input))
        let topLevel = try PDFWriter.indexTopLevelObjects(bytes)
        XCTAssertNotNil(topLevel[7], "precondition: the length lives in its own object")

        let packed = PDFWriter.indexObjectStreams(bytes, topLevel: topLevel)
        XCTAssertEqual(Set(packed.keys), [1, 2, 3], "the stream still decodes whole")

        let output = try sibling(of: input, "objstm-indirect-ocr.pdf")
        try write(input, to: output)
        XCTAssertTrue(try supersededPageDict(in: output, objNum: 3).contains("/MediaBox"))
        XCTAssertNotNil(PDFDocument(url: output))
    }

    /// Offsets past 65535 need a wider cross-reference field than the small fixture exercises;
    /// a hard-coded two-byte field would silently truncate every offset in a real document.
    func testWideCrossReferenceOffsetsAreEmitted() throws {
        let input = try Fixtures.objectStreamPDF(name: "objstm-wide.pdf", padTo: 90_000)
        XCTAssertGreaterThan(try Data(contentsOf: input).count, 1 << 16, "precondition: past 2 bytes")

        let output = try sibling(of: input, "objstm-wide-ocr.pdf")
        try write(input, to: output)
        let appended = try Data(contentsOf: output).dropFirst(try Data(contentsOf: input).count)
        XCTAssertNotNil(String(decoding: appended, as: UTF8.self).range(of: "/W [ 1 3 2 ]"),
                        "a three-byte offset field is required at this file size")

        let doc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").contains("HELLO"))
    }

    /// An object stream this writer cannot decode must fail loud, not guess. A predictor in
    /// `/DecodeParms` is the realistic case.
    func testUndecodableObjectStreamFailsLoudRatherThanSilently() throws {
        let input = try Fixtures.objectStreamPDF()
        var raw = try Data(contentsOf: input)
        guard let range = raw.range(of: Data("/Filter /FlateDecode".utf8)) else {
            return XCTFail("fixture shape changed")
        }
        // Same byte count, so every recorded offset stays valid.
        raw.replaceSubrange(range, with: Data("/Filter /Bespoke1234".utf8))
        let armed = try sibling(of: input, "objstm-unreadable.pdf")
        try raw.write(to: armed)

        let bytes = [UInt8](raw)
        let topLevel = try PDFWriter.indexTopLevelObjects(bytes)
        XCTAssertTrue(PDFWriter.indexObjectStreams(bytes, topLevel: topLevel).isEmpty,
                      "an unsupported filter must be refused, never mis-decoded")

        let output = try sibling(of: input, "objstm-unreadable-ocr.pdf")
        XCTAssertThrowsError(try write(armed, to: output)) {
            XCTAssertEqual($0 as? PDFWriterError, .unsupportedStructure)
        }
    }

    // MARK: - Per-job memory bound (M6 / S12)

    /// An input past the ceiling fails that file inline rather than letting one job take the
    /// machine with it. The fixture is a sparse file, so it costs no disk.
    func testOversizedInputIsRefusedNotAttempted() throws {
        let url = try Fixtures.uniqueURL("oversized.pdf")
        FileManager.default.createFile(atPath: url.path, contents: Data("%PDF-1.5\n".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PDFWriter.maxInputBytes) + 1)
        try handle.close()

        let output = try sibling(of: url, "oversized-ocr.pdf")
        XCTAssertThrowsError(try write(url, to: output)) {
            XCTAssertEqual($0 as? PDFWriterError, .inputTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// The writer must not hold the file. Peak footprint growth across the call is compared with
    /// the input size: the previous implementation held `Data` + `[UInt8]` + the grown output
    /// buffer, so growth tracked ~3x the file; mapping and streaming keeps it far below 1x.
    func testWriterDoesNotHoldWholeCopiesOfTheInput() throws {
        let input = try Fixtures.repeatedImagePDF(pages: 12)          // tens of MB
        let size = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as! Int
        try XCTSkipIf(size < 8 << 20, "fixture too small to measure meaningfully")

        let output = try sibling(of: input, "footprint-ocr.pdf")
        let before = Self.residentFootprint()
        try write(input, to: output)
        let growth = Self.residentFootprint() - before

        XCTAssertLessThan(growth, size,
                          "peak growth \(growth) B against a \(size) B input — the writer is "
                          + "holding at least one whole copy")
        XCTAssertEqual(try Data(contentsOf: output).prefix(size), try Data(contentsOf: input),
                       "streaming the output must still leave the original a verbatim prefix")
    }

    private static func residentFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: - helpers

    /// The writer's full view of a file: top-level objects plus anything packed into an
    /// `/ObjStm`.
    private func fullIndex(_ bytes: [UInt8]) throws -> PDFWriter.ObjectIndex {
        let topLevel = try PDFWriter.indexTopLevelObjects(bytes)
        return PDFWriter.ObjectIndex(topLevel: topLevel,
                                     packed: PDFWriter.indexObjectStreams(bytes, topLevel: topLevel))
    }

    /// Run the writer over `input`, putting one text run on page 0.
    private func write(_ input: URL, to output: URL) throws {
        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO",
                                          boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])
    }

    /// The **superseding** dictionary the writer appended for `objNum` — the later definition of
    /// that object number wins, which is what a reader sees.
    private func supersededPageDict(in output: URL, objNum: Int) throws -> String {
        let bytes = [UInt8](try Data(contentsOf: output))
        let dict = try XCTUnwrap(PDFWriter.objectDict(bytes, objects: try fullIndex(bytes), objNum: objNum))
        return String(decoding: dict.bytes, as: UTF8.self)
    }

    private func supersededPageDictCount(of key: String, in output: URL, objNum: Int) throws -> Int {
        try supersededPageDict(in: output, objNum: objNum).components(separatedBy: key).count - 1
    }

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.01, file: file, line: line)
    }

    private func sibling(of url: URL, _ name: String) throws -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name)
    }
}
