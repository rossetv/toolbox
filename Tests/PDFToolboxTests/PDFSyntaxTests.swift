// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import PDFToolbox

/// Lexical-layer tests. Each one pins a rule the previous string-based scanner broke, so each
/// fails against that scanner and passes against the byte-level one.
final class PDFSyntaxTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func value(_ key: String, in dict: String) -> String? {
        let b = bytes(dict)
        guard let r = PDFSyntax.dictValue(of: key, in: b, dictAt: 0) else { return nil }
        return String(decoding: b[r], as: UTF8.self)
    }

    // MARK: - Token boundaries (C1)

    func testStreamKeywordIsNotMatchedInsideAWord() {
        let b = bytes("/BaseFont /BitstreamVeraSans")
        let kw = Array("stream".utf8)
        let inWord = b.indices.first { PDFSyntax.matches(b, at: $0, kw) }
        XCTAssertNotNil(inWord, "the substring really is there — that is the trap")
        XCTAssertFalse(PDFSyntax.isKeyword(b, at: inWord!, kw),
                       "`stream` inside `Bitstream` is not the stream keyword")
    }

    func testKeywordMatchesAtRealBoundaries() {
        let b = bytes(">>\nstream\n")
        XCTAssertTrue(PDFSyntax.isKeyword(b, at: 3, Array("stream".utf8)))
    }

    func testObjKeywordIsNotMatchedInsideEndobj() {
        let b = bytes("endobj")
        XCTAssertFalse(PDFSyntax.isKeyword(b, at: 3, Array("obj".utf8)))
    }

    // MARK: - String literals (S5)

    func testDictionaryEndIsNotClosedByAngleBracketsInsideAString() {
        let dict = "<< /Type /Page /Title (chapter >> appendix) /Contents 5 0 R >>"
        let b = bytes(dict)
        XCTAssertEqual(PDFSyntax.endOfDictionary(b, from: 0), b.count,
                       "a `>>` inside a literal string must not close the dictionary")
        XCTAssertEqual(value("Contents", in: dict), "5 0 R")
    }

    func testKeyIsFoundWhenAStringContainsAnOpeningDictionary() {
        let dict = "<< /Type /Page /Title (a << b) /Contents 5 0 R >>"
        XCTAssertEqual(value("Contents", in: dict), "5 0 R",
                       "a `<<` inside a literal string must not raise the nesting depth")
    }

    func testNestedAndEscapedParenthesesAreHandled() {
        XCTAssertEqual(value("Contents", in: "<< /T (a (b) >> c) /Contents 7 0 R >>"), "7 0 R")
        XCTAssertEqual(value("Contents", in: "<< /T (a \\) >> b) /Contents 7 0 R >>"), "7 0 R")
        XCTAssertEqual(value("Contents", in: "<< /T (a \\\\) /Contents 7 0 R >>"), "7 0 R")
    }

    func testHexStringsAreSkipped() {
        XCTAssertEqual(value("Contents", in: "<< /ID <3E3E3C3C> /Contents 7 0 R >>"), "7 0 R")
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(value("Contents", in: "<< /T 1 % a >> comment\n /Contents 7 0 R >>"), "7 0 R")
    }

    // MARK: - CRLF is two bytes, not one Character (M7 / S6)

    func testCRLFBetweenKeyAndValueIsASeparator() {
        // The exact shape Swift's grapheme clustering hides: "\r\n" is ONE Character.
        XCTAssertEqual(Array("/Contents\r\n5 0 R").count, 15, "precondition: CRLF is one Character")
        XCTAssertEqual(value("Contents", in: "<< /Type /Page /Contents\r\n5 0 R /X 1 >>"), "5 0 R")
    }

    func testCRLFAfterTheOpeningBraceAndBetweenEntries() {
        let dict = "<<\r\n/Type /Page\r\n/Contents 5 0 R\r\n/MediaBox [ 0 0 612 792 ]\r\n>>"
        XCTAssertEqual(value("Contents", in: dict), "5 0 R")
        XCTAssertEqual(value("MediaBox", in: dict), "[ 0 0 612 792 ]")
    }

    // MARK: - Key/value pairing

    func testANameUsedAsAValueIsNotMistakenForAKey() {
        // `/Type`'s value is the name `/Contents`; the real `/Contents` entry follows it.
        XCTAssertEqual(value("Contents", in: "<< /Type /Contents /Contents 9 0 R >>"), "9 0 R")
    }

    func testKeyPrefixDoesNotMatch() {
        XCTAssertNil(value("Contents", in: "<< /ContentsX 5 0 R >>"))
    }

    func testEscapedNameIsDecoded() {
        XCTAssertEqual(value("Contents", in: "<< /C#6Fntents 5 0 R >>"), "5 0 R",
                       "`#XX` name escapes must not hide a key from the scanner")
    }

    func testNestedDictionaryKeysAreNotSeenAtTheTopLevel() {
        XCTAssertNil(value("Font", in: "<< /Resources << /Font << /F1 1 0 R >> >> >>"))
        XCTAssertEqual(value("Resources", in: "<< /Resources << /Font << /F1 1 0 R >> >> >>"),
                       "<< /Font << /F1 1 0 R >> >>")
    }

    // MARK: - Value extents

    func testValueExtents() {
        XCTAssertEqual(value("A", in: "<< /A 42 /B 1 >>"), "42")
        XCTAssertEqual(value("A", in: "<< /A 5 0 R /B 1 >>"), "5 0 R")
        XCTAssertEqual(value("A", in: "<< /A true /B 1 >>"), "true")
        XCTAssertEqual(value("A", in: "<< /A -3.5 /B 1 >>"), "-3.5")
        XCTAssertEqual(value("A", in: "<< /A /Name /B 1 >>"), "/Name")
        XCTAssertEqual(value("A", in: "<< /A [ 1 0 R 2 0 R ] /B 1 >>"), "[ 1 0 R 2 0 R ]")
        XCTAssertEqual(value("A", in: "<< /A [ [ 1 ] [ 2 ] ] /B 1 >>"), "[ [ 1 ] [ 2 ] ]")
        XCTAssertEqual(value("A", in: "<< /A (text) /B 1 >>"), "(text)")
    }

    // MARK: - Implausible integers (S4)

    func testImplausibleIntegersAreRefusedRatherThanSaturated() {
        XCTAssertNil(PDFSyntax.parseInt(Array("9223372036854775807".utf8)))
        XCTAssertNil(PDFSyntax.parseInt(Array("99999999999999999999999".utf8)))
        XCTAssertEqual(PDFSyntax.parseInt(Array("12345".utf8)), 12345)
        XCTAssertNil(PDFSyntax.parseInt(Array("-5".utf8)))
        XCTAssertNil(PDFSyntax.parseInt(Array("3.5".utf8)))
    }

    // MARK: - Reference arrays

    func testRefArrayParsing() {
        let refs = PDFSyntax.parseRefArray(Array("[ 3 0 R 4 0 R 12 1 R ]".utf8))
        XCTAssertEqual(refs.map(\.num), [3, 4, 12])
        XCTAssertEqual(refs.map(\.gen), [0, 0, 1])
        XCTAssertEqual(PDFSyntax.parseRefArray(Array("[\r\n3 0 R\r\n4 0 R\r\n]".utf8)).map(\.num), [3, 4])
        XCTAssertTrue(PDFSyntax.parseRefArray(Array("[ ]".utf8)).isEmpty)
    }
}
