// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The lexical layer of PDF syntax (PDF 32000-1 §7.2–§7.3), byte for byte.
///
/// **Everything here operates on bytes, never on `Character`s.** That is not a style choice:
/// PDF separates tokens with any whitespace, CRLF included, and Swift collapses a CR byte
/// followed by an LF byte into a *single* extended grapheme cluster that compares equal to
/// neither `"\r"` nor `"\n"`. A scanner built on `Array(someString)` therefore fails to see the
/// separator, misses the key it was looking for, and the caller writes a duplicate entry into
/// the document. Bytes have no such ambiguity.
///
/// Every function is index-agnostic — it works from the collection's own `startIndex`/`endIndex`
/// and returns absolute indices — so a slice of a larger buffer can be scanned without rebasing.
enum PDFSyntax {

    // MARK: - Character classes (PDF 32000-1 §7.2.2, tables 1 and 2)

    /// The six bytes PDF counts as whitespace, NUL included.
    static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x00 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D || b == 0x20
    }

    /// `( ) < > [ ] { } / %` — the bytes that end a token without being part of it.
    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    /// A "regular" byte: anything that can sit *inside* a token.
    static func isRegular(_ b: UInt8) -> Bool { !isWhitespace(b) && !isDelimiter(b) }

    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    // MARK: - Scanning primitives

    /// Index of the next significant byte at or after `i`, skipping whitespace and `%` comments.
    static func skipSpace<C: RandomAccessCollection>(_ b: C, from i: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        var i = i
        while i < b.endIndex {
            if isWhitespace(b[i]) {
                i += 1
            } else if b[i] == 0x25 {                       // '%' — comment runs to the line end
                while i < b.endIndex, b[i] != 0x0A, b[i] != 0x0D { i += 1 }
            } else {
                break
            }
        }
        return i
    }

    static func matches<C: RandomAccessCollection>(_ b: C, at i: Int, _ pat: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        guard i >= b.startIndex, i + pat.count <= b.endIndex else { return false }
        for k in 0..<pat.count where b[i + k] != pat[k] { return false }
        return true
    }

    /// True when `pat` sits at `i` as a **complete token** — bounded on both sides by whitespace,
    /// a delimiter, or the edge of the buffer.
    ///
    /// This boundary rule is the whole point of the function. `stream` occurs inside the
    /// perfectly ordinary font name `/BaseFont /BitstreamVeraSans`, and a scanner that accepts a
    /// bare substring match treats that as the start of a stream body, skips forward to the next
    /// `endstream`, and silently loses every object header in between.
    static func isKeyword<C: RandomAccessCollection>(_ b: C, at i: Int, _ pat: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        guard matches(b, at: i, pat) else { return false }
        if i > b.startIndex, isRegular(b[i - 1]) { return false }
        let after = i + pat.count
        if after < b.endIndex, isRegular(b[after]) { return false }
        return true
    }

    /// The bytes of the token starting at or after `from`, or nil when the next significant byte
    /// is a delimiter or the buffer ends.
    static func readToken<C: RandomAccessCollection>(_ b: C, from: Int) -> (bytes: [UInt8], end: Int)?
    where C.Element == UInt8, C.Index == Int {
        let start = skipSpace(b, from: from)
        guard start < b.endIndex, isRegular(b[start]) else { return nil }
        var end = start
        while end < b.endIndex, isRegular(b[end]) { end += 1 }
        return (Array(b[start..<end]), end)
    }

    // MARK: - Composite objects

    /// End index (exclusive) of the literal string starting at the `(` at `from`. Honours nested
    /// parentheses and `\` escapes, so `(a \) b)` and `(a (b) c)` both end where they should.
    static func endOfLiteralString<C: RandomAccessCollection>(_ b: C, from: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        var depth = 0
        var i = from
        while i < b.endIndex {
            let c = b[i]
            if c == 0x5C { i += 2; continue }                       // backslash escape
            if c == 0x28 { depth += 1 }
            else if c == 0x29 { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return b.endIndex
    }

    /// End index (exclusive) of the hex string starting at the `<` at `from`. The caller must
    /// already have ruled out `<<`.
    static func endOfHexString<C: RandomAccessCollection>(_ b: C, from: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        var i = from + 1
        while i < b.endIndex, b[i] != 0x3E { i += 1 }
        return min(i + 1, b.endIndex)
    }

    /// End index (exclusive) of the array starting at the `[` at `from`.
    static func endOfArray<C: RandomAccessCollection>(_ b: C, from: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        var depth = 0
        var i = from
        while i < b.endIndex {
            let c = b[i]
            if c == 0x25 { i = skipSpace(b, from: i); continue }
            if c == 0x28 { i = endOfLiteralString(b, from: i); continue }
            if c == 0x3C {
                if i + 1 < b.endIndex, b[i + 1] == 0x3C {
                    i = endOfDictionary(b, from: i) ?? b.endIndex
                } else {
                    i = endOfHexString(b, from: i)
                }
                continue
            }
            if c == 0x5B { depth += 1; i += 1; continue }
            if c == 0x5D { depth -= 1; i += 1; if depth == 0 { return i }; continue }
            i += 1
        }
        return b.endIndex
    }

    /// End index (exclusive) of the `<< … >>` dictionary starting at `from`, or nil if `from`
    /// is not a dictionary or the dictionary never closes.
    ///
    /// Literal strings, hex strings and comments are skipped wholesale, so a `>>` written inside
    /// a string value — `/Title (chapter >> appendix)`, entirely legal — cannot close the
    /// dictionary early and hand the caller a truncated, syntactically broken fragment.
    static func endOfDictionary<C: RandomAccessCollection>(_ b: C, from: Int) -> Int?
    where C.Element == UInt8, C.Index == Int {
        guard from + 1 < b.endIndex, b[from] == 0x3C, b[from + 1] == 0x3C else { return nil }
        var depth = 0
        var i = from
        while i < b.endIndex {
            let c = b[i]
            if c == 0x25 { i = skipSpace(b, from: i); continue }
            if c == 0x28 { i = endOfLiteralString(b, from: i); continue }
            if c == 0x3C {
                if i + 1 < b.endIndex, b[i + 1] == 0x3C { depth += 1; i += 2; continue }
                i = endOfHexString(b, from: i)
                continue
            }
            if c == 0x3E, i + 1 < b.endIndex, b[i + 1] == 0x3E {
                depth -= 1
                i += 2
                if depth == 0 { return i }
                continue
            }
            i += 1
        }
        return nil
    }

    /// End index (exclusive) of the object value starting at `from`: a dictionary, array, string,
    /// hex string, name, an `N G R` reference, a number, or a keyword such as `true`.
    static func endOfValue<C: RandomAccessCollection>(_ b: C, from: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        guard from < b.endIndex else { return from }
        switch b[from] {
        case 0x3C where from + 1 < b.endIndex && b[from + 1] == 0x3C:
            return endOfDictionary(b, from: from) ?? b.endIndex
        case 0x3C:
            return endOfHexString(b, from: from)
        case 0x28:
            return endOfLiteralString(b, from: from)
        case 0x5B:
            return endOfArray(b, from: from)
        case 0x2F:                                              // a name
            var i = from + 1
            while i < b.endIndex, isRegular(b[i]) { i += 1 }
            return i
        default:
            // A number, a keyword, or the three tokens of an `N G R` indirect reference. Only
            // two integers followed by `R` extend the value beyond its first token.
            guard let first = readToken(b, from: from) else { return from }
            guard isInteger(first.bytes) else { return first.end }
            guard let second = readToken(b, from: first.end), isInteger(second.bytes),
                  let third = readToken(b, from: second.end), third.bytes == [0x52] else {
                return first.end
            }
            return third.end
        }
    }

    // MARK: - Dictionary lookup

    /// The byte range of the value of `/key` at the **top level** of the dictionary that starts at
    /// `dictAt`, or nil when the dictionary has no such key.
    ///
    /// Walks the dictionary strictly as key/value pairs rather than hunting for the key's bytes:
    /// a name that appears as a *value* (`/Type /Contents`) must not be mistaken for the key of
    /// the pair that follows it.
    /// The outcome of looking a key up in a dictionary.
    ///
    /// `absent` and `unparseable` must never be conflated. A caller that treats "I could not read
    /// this dictionary" as "the key is not there" will happily insert a second copy of a key that
    /// was already present further along — and a duplicate key makes the whole dictionary's
    /// meaning undefined (PDF 32000-1 §7.3.7).
    enum DictLookup {
        case found(Range<Int>)
        case absent
        case unparseable
    }

    static func dictLookup<C: RandomAccessCollection>(of key: String, in b: C, dictAt: Int) -> DictLookup
    where C.Element == UInt8, C.Index == Int {
        guard dictAt + 1 < b.endIndex, b[dictAt] == 0x3C, b[dictAt + 1] == 0x3C else { return .unparseable }
        let target = Array(key.utf8)
        var i = dictAt + 2
        while true {
            i = skipSpace(b, from: i)
            guard i < b.endIndex else { return .unparseable }    // ran off the end before `>>`
            if b[i] == 0x3E {
                // `>>` ends the dictionary — a LONE `>` does not. Accepting one as the end marker
                // reports "key absent" for a dictionary we actually failed to read, which is
                // exactly the conflation this type exists to prevent: the caller would then insert
                // a key that is already present further along, past the malformed byte.
                guard i + 1 < b.endIndex, b[i + 1] == 0x3E else { return .unparseable }
                return .absent                                  // read the whole dict, no key
            }
            guard b[i] == 0x2F else { return .unparseable }      // not a key where one must be
            var nameEnd = i + 1
            while nameEnd < b.endIndex, isRegular(b[nameEnd]) { nameEnd += 1 }
            let name = decodeName(Array(b[(i + 1)..<nameEnd]))
            let valueStart = skipSpace(b, from: nameEnd)
            let valueEnd = endOfValue(b, from: valueStart)
            guard valueEnd > valueStart else { return .unparseable }   // value could not be bounded
            if name == target { return .found(valueStart..<valueEnd) }
            i = valueEnd
        }
    }

    /// The range of `/key`'s value, or nil if it is absent **or** the dictionary is unreadable.
    ///
    /// Callers that go on to *modify* the dictionary must use `dictLookup` instead and treat
    /// `unparseable` as an error — see `DictLookup`.
    static func dictValue<C: RandomAccessCollection>(of key: String, in b: C, dictAt: Int) -> Range<Int>?
    where C.Element == UInt8, C.Index == Int {
        if case .found(let range) = dictLookup(of: key, in: b, dictAt: dictAt) { return range }
        return nil
    }

    /// The value of `/key` as a name (`/Page` → `"Page"`), or nil if absent or not a name.
    static func dictName<C: RandomAccessCollection>(of key: String, in b: C, dictAt: Int) -> String?
    where C.Element == UInt8, C.Index == Int {
        guard let r = dictValue(of: key, in: b, dictAt: dictAt), r.count > 1, b[r.lowerBound] == 0x2F else {
            return nil
        }
        return String(decoding: decodeName(Array(b[(r.lowerBound + 1)..<r.upperBound])), as: UTF8.self)
    }

    /// The value of `/key` as a non-negative integer, or nil if absent, negative or not an integer.
    static func dictInt<C: RandomAccessCollection>(of key: String, in b: C, dictAt: Int) -> Int?
    where C.Element == UInt8, C.Index == Int {
        guard let r = dictValue(of: key, in: b, dictAt: dictAt) else { return nil }
        return parseInt(Array(b[r]))
    }

    /// The value of `/key` as an `N G R` reference, or nil.
    static func dictRef<C: RandomAccessCollection>(of key: String, in b: C, dictAt: Int) -> (num: Int, gen: Int)?
    where C.Element == UInt8, C.Index == Int {
        guard let r = dictValue(of: key, in: b, dictAt: dictAt) else { return nil }
        return parseRef(Array(b[r]))
    }

    /// PDF name escapes: `#XX` is a hex-encoded byte, so `/C#6Fntents` names the same key as
    /// `/Contents`. Decoding matters at a trust boundary — a hostile producer that escapes one
    /// byte of a key would otherwise hide it from the scanner entirely.
    static func decodeName(_ raw: [UInt8]) -> [UInt8] {
        guard raw.contains(0x23) else { return raw }             // '#'
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            if raw[i] == 0x23, i + 2 < raw.count,
               let hi = hexDigit(raw[i + 1]), let lo = hexDigit(raw[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(raw[i])
                i += 1
            }
        }
        return out
    }

    private static func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - Number and reference parsing

    static func isInteger(_ token: [UInt8]) -> Bool {
        var i = 0
        if i < token.count, token[i] == 0x2B || token[i] == 0x2D { i += 1 }
        guard i < token.count else { return false }
        while i < token.count {
            guard isDigit(token[i]) else { return false }
            i += 1
        }
        return true
    }

    /// A non-negative integer, or nil when the token is not one **or is implausibly large**.
    ///
    /// The ceiling is deliberate. `Int(digits)` on a 19-digit object number yields `Int.max`, and
    /// the first `+= 1` the writer performs on it traps and takes the whole process down — a
    /// crash reachable from 27 bytes of untrusted input. Nothing legitimate in a PDF needs a
    /// value this large, so refusing it costs nothing.
    static let maxPlausibleInteger = 1 << 40

    static func parseInt(_ token: [UInt8]) -> Int? {
        guard isInteger(token), token.first != 0x2D else { return nil }
        var value = 0
        for b in token where isDigit(b) {
            let (m, mo) = value.multipliedReportingOverflow(by: 10)
            guard !mo else { return nil }
            let (s, so) = m.addingReportingOverflow(Int(b - 0x30))
            guard !so, s <= maxPlausibleInteger else { return nil }
            value = s
        }
        return value
    }

    /// `N G R` split into its parts, or nil.
    static func parseRef(_ bytes: [UInt8]) -> (num: Int, gen: Int)? {
        guard let n = readToken(bytes, from: 0), let num = parseInt(n.bytes),
              let g = readToken(bytes, from: n.end), let gen = parseInt(g.bytes),
              let r = readToken(bytes, from: g.end), r.bytes == [0x52] else { return nil }
        return (num, gen)
    }

    /// Every `N G R` reference inside an array (or a bare run of them).
    static func parseRefArray(_ bytes: [UInt8]) -> [(num: Int, gen: Int)] {
        var refs: [(num: Int, gen: Int)] = []
        var i = 0
        var pending: [Int] = []
        while i < bytes.count {
            guard let tok = readToken(bytes, from: i) else {
                // Step over a delimiter (`[`, `]`, …) and carry on.
                let next = skipSpace(bytes, from: i)
                if next >= bytes.count { break }
                i = next + 1
                continue
            }
            i = tok.end
            if tok.bytes == [0x52] {                             // "R"
                if pending.count >= 2 {
                    let gen = pending.removeLast()
                    let num = pending.removeLast()
                    refs.append((num, gen))
                }
                pending.removeAll()
            } else if let v = parseInt(tok.bytes) {
                pending.append(v)
                if pending.count > 2 { pending.removeFirst() }
            } else {
                pending.removeAll()
            }
        }
        return refs
    }
}
