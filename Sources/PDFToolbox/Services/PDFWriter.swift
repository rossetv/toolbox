// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// One recognised text run and where Vision saw it. `boundingBox` is **Vision-normalised**:
/// origin bottom-left, x/y/width/height in 0…1, measured in the page's **displayed**
/// (rotation-applied) space. `PDFWriter` — not the caller — turns this into PDF user space.
struct PositionedText: Equatable {
    let text: String
    let boundingBox: CGRect
}

/// The geometry `PDFWriter` needs to place a page's text layer: the unrotated `mediaBox`
/// and the page's `/Rotate` (degrees clockwise, 0/90/180/270).
struct PageGeometry: Equatable {
    let mediaBox: CGRect
    let rotation: Int
}

enum PDFWriterError: Error, LocalizedError {
    case cannotRead
    case malformedPDF
    /// A page (or the catalog) we must supersede is not a top-level indirect object — it is
    /// packed in a compressed object stream (`/ObjStm`). v1 does not unpack object streams;
    /// the file fails inline so the batch continues (spec R2-N3).
    case unsupportedStructure

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "The PDF could not be read."
        case .malformedPDF: return "The PDF structure could not be parsed."
        case .unsupportedStructure:
            return "This PDF uses a compressed object layout that OCR cannot amend in v1."
        }
    }
}

/// Adds an invisible, selectable OCR text layer to chosen pages **by PDF incremental update**:
/// the original bytes are the verbatim prefix of the output, and only new objects + a new xref
/// section + a trailer with `/Prev` are appended. The original page's image XObject streams are
/// never rewritten, so the rendered appearance is unchanged (spec §6). `PDFWriter` owns the
/// Vision-normalised → PDF-user-space coordinate transform, including `mediaBox` origin and
/// page rotation.
///
/// Locating the page objects uses a minimal top-level tokeniser (stream bodies skipped) rather
/// than a full xref parser, so both classic-xref and cross-reference-stream PDFs work. A page
/// packed inside an object stream throws `.unsupportedStructure` (fail-loud, never silent
/// corruption).
///
/// Non-Latin scripts: the layer uses base-14 Helvetica + WinAnsi, which extracts ASCII/Latin
/// text. CJK/Arabic would need an embedded font + `/ToUnicode` CMap — a conscious v1 deferral.
struct PDFWriter {

    func appendTextLayer(to input: URL,
                         output: URL,
                         pageText: [Int: [PositionedText]],
                         geometry: [Int: PageGeometry]) throws {
        guard let data = try? Data(contentsOf: input) else { throw PDFWriterError.cannotRead }

        // Pages that actually carry recognised text.
        let targets = pageText.filter { !$0.value.isEmpty }.keys.sorted()
        guard !targets.isEmpty else {
            // Nothing to add — emit the original bytes verbatim (a valid no-op output).
            try data.write(to: output)
            return
        }

        let bytes = [UInt8](data)
        let index = try Self.indexTopLevelObjects(bytes)
        let root = try Self.findRoot(bytes, objects: index)
        let pageObjs = try Self.orderedPageObjects(bytes, objects: index, root: root)

        var maxObj = index.keys.max() ?? 0
        func allocate() -> Int { maxObj += 1; return maxObj }

        // One shared Helvetica font object for every appended layer.
        let fontObj = allocate()
        let fontName = "PDFTBox"   // resource key; unlikely to collide with a scan's resources

        // Accumulate appended objects; record each object's byte offset in the output.
        var appended = Data()
        appended.append(0x0A)   // separate from the original's trailing %%EOF
        var offsets: [Int: (offset: Int, gen: Int)] = [:]
        let baseLen = data.count

        func emit(objNum: Int, gen: Int, body: String) {
            offsets[objNum] = (baseLen + appended.count, gen)
            let head = "\(objNum) \(gen) obj\n"
            appended.append(latin1(head))
            appended.append(latin1(body))
            appended.append(latin1("\nendobj\n"))
        }

        // Font object.
        emit(objNum: fontObj, gen: 0,
             body: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

        for pageIndex in targets {
            guard let objNum = pageObjs[safe: pageIndex] else { continue }
            guard let geo = geometry[pageIndex] else { throw PDFWriterError.malformedPDF }
            let boxes = pageText[pageIndex] ?? []

            // Read the page dict (ASCII; a page object is a dict, never a stream).
            guard let (dictText, gen) = Self.objectDictText(bytes, objects: index, objNum: objNum) else {
                throw PDFWriterError.malformedPDF
            }

            // Build the invisible-text content stream for this page.
            let contentObj = allocate()
            let content = Self.contentStream(for: boxes, geometry: geo, fontResource: fontName)
            let contentBody = latin1(content)
            emit(objNum: contentObj, gen: 0,
                 body: "<< /Length \(contentBody.count) >>\nstream\n\(content)\nendstream")

            // Supersede the page dict: append our content ref, ensure our font in /Resources.
            let newPageDict = try Self.superseded(pageDict: dictText,
                                                  addContent: contentObj,
                                                  fontResource: fontName,
                                                  fontObj: fontObj,
                                                  bytes: bytes,
                                                  objects: index,
                                                  emit: { emit(objNum: $0, gen: $1, body: $2) })
            emit(objNum: objNum, gen: gen, body: newPageDict)
        }

        // New classic xref section + trailer with /Prev → the previous startxref.
        let prev = try Self.lastStartxref(bytes)
        let xrefOffset = baseLen + appended.count
        appended.append(latin1(Self.xrefSection(offsets: offsets)))
        let size = (offsets.keys.max() ?? maxObj) + 1
        let trailer = "trailer\n<< /Size \(size) /Root \(root.num) \(root.gen) R /Prev \(prev) >>\n"
            + "startxref\n\(xrefOffset)\n%%EOF\n"
        appended.append(latin1(trailer))

        var out = data
        out.append(appended)
        try out.write(to: output)
    }

    // MARK: - Coordinate transform (PDFWriter owns it)

    /// The page's size as displayed (rotation applied): width/height swap at 90°/270°.
    static func displayedSize(mediaBox: CGRect, rotation: Int) -> CGSize {
        let r = ((rotation % 360) + 360) % 360
        return (r == 90 || r == 270)
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : CGSize(width: mediaBox.width, height: mediaBox.height)
    }

    /// Map a point in **displayed** space (bottom-left origin, points relative to the displayed
    /// page) back to **unrotated PDF user space** (incl. the `mediaBox` origin). This inverts the
    /// viewer's clockwise `/Rotate`. Derived from first principles (see the per-case formulas);
    /// `w`/`h` are the unrotated media width/height.
    static func userPoint(displayed p: CGPoint, mediaBox: CGRect, rotation: Int) -> CGPoint {
        let w = mediaBox.width, h = mediaBox.height
        let r = ((rotation % 360) + 360) % 360
        let local: CGPoint
        switch r {
        case 90:  local = CGPoint(x: w - p.y, y: p.x)          // forward: X=y, Y=w−x
        case 180: local = CGPoint(x: w - p.x, y: h - p.y)      // forward: X=w−x, Y=h−y
        case 270: local = CGPoint(x: p.y, y: h - p.x)          // forward: X=h−y, Y=x
        default:  local = p                                    // 0°: identity
        }
        return CGPoint(x: local.x + mediaBox.minX, y: local.y + mediaBox.minY)
    }

    /// Placement for one normalised box: the baseline origin in user space, the text rotation
    /// (degrees CCW, so the layer reads the same way as the displayed glyphs), the font size
    /// (points) and a horizontal scale that fits the run to the box width.
    static func placement(for box: PositionedText,
                          geometry: PageGeometry) -> (origin: CGPoint, angle: Int, size: CGFloat, hScale: CGFloat) {
        let displayed = displayedSize(mediaBox: geometry.mediaBox, rotation: geometry.rotation)
        let b = box.boundingBox
        // Bottom-left of the box in displayed points → user space (reading start).
        let originDisplayed = CGPoint(x: b.minX * displayed.width, y: b.minY * displayed.height)
        let origin = userPoint(displayed: originDisplayed, mediaBox: geometry.mediaBox, rotation: geometry.rotation)
        let size = max(1, b.height * displayed.height)
        let boxWidthPts = max(1, b.width * displayed.width)
        // Helvetica averages ~0.5 em/char; scale so the run spans the box (selection aligns).
        let natural = max(1, CGFloat(box.text.count) * 0.5 * size)
        let hScale = min(1000, max(1, boxWidthPts / natural * 100))
        let angle = (((geometry.rotation % 360) + 360) % 360)
        return (origin, angle, size, hScale)
    }

    // MARK: - Content stream

    private static func contentStream(for boxes: [PositionedText],
                                      geometry: PageGeometry,
                                      fontResource: String) -> String {
        var s = "q\n"
        for box in boxes where !box.text.isEmpty {
            let p = placement(for: box, geometry: geometry)
            let (a, b, c, d) = rotationMatrix(degreesCCW: p.angle)
            let tm = String(format: "%.4f %.4f %.4f %.4f %.2f %.2f Tm",
                            a, b, c, d, p.origin.x, p.origin.y)
            s += "BT\n3 Tr\n"                                   // render mode 3 = invisible
            s += "/\(fontResource) \(fmt(p.size)) Tf\n"
            s += "\(fmt(p.hScale)) Tz\n"
            s += "\(tm)\n"
            s += "(\(escapePDFString(box.text))) Tj\n"
            s += "ET\n"
        }
        s += "Q"
        return s
    }

    /// Rotation matrix (a b c d) for `θ` degrees counter-clockwise.
    private static func rotationMatrix(degreesCCW: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch (((degreesCCW % 360) + 360) % 360) {
        case 90:  return (0, 1, -1, 0)
        case 180: return (-1, 0, 0, -1)
        case 270: return (0, -1, 1, 0)
        default:  return (1, 0, 0, 1)
        }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    /// Escape a string for a PDF literal `( )`: backslash-escape `\ ( )`, drop control bytes,
    /// map non-Latin-1 to `?` (WinAnsi/Helvetica cannot render it — a conscious v1 limitation).
    static func escapePDFString(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "(": out += "\\("
            case ")": out += "\\)"
            default:
                let v = scalar.value
                if v >= 0x20 && v <= 0xFF { out.unicodeScalars.append(scalar) }
                else if v == 0x09 { out += " " }
                else { out += "?" }
            }
        }
        return out
    }

    // MARK: - Page-dict supersession

    /// Rewrite a page dict so it also draws our content stream and can resolve our font.
    /// `emit` is used when `/Resources` is an indirect object we must supersede too.
    private static func superseded(pageDict: String,
                                   addContent contentObj: Int,
                                   fontResource: String,
                                   fontObj: Int,
                                   bytes: [UInt8],
                                   objects: [Int: (offset: Int, gen: Int)],
                                   emit: (Int, Int, String) -> Void) throws -> String {
        var dict = pageDict

        // --- /Contents: make it an array ending in our content ref. ---
        let contentRef = "\(contentObj) 0 R"
        if let value = topLevelValue(of: "Contents", in: dict) {
            let replacement: String
            if value.text.hasPrefix("[") {
                // [ a 0 R b 0 R ] → [ a 0 R b 0 R contentRef ]
                let inner = String(value.text.dropFirst().dropLast())
                replacement = "[ \(inner.trimmingCharacters(in: .whitespacesAndNewlines)) \(contentRef) ]"
            } else {
                // single ref → array of the two
                replacement = "[ \(value.text) \(contentRef) ]"
            }
            dict.replaceSubrange(value.range, with: replacement)
        } else {
            dict = insertIntoDict(dict, entry: "/Contents [ \(contentRef) ]")
        }

        // --- /Resources: ensure /Font << /<res> fontObj 0 R >>. ---
        let fontEntry = "/\(fontResource) \(fontObj) 0 R"
        if let value = topLevelValue(of: "Resources", in: dict) {
            if value.text.hasPrefix("<<") {
                let merged = insertFont(intoResources: value.text, fontEntry: fontEntry)
                dict.replaceSubrange(value.range, with: merged)
            } else if let ref = parseRef(value.text) {
                // Supersede the shared resources object, adding our font.
                guard let (resDict, resGen) = objectDictText(bytes, objects: objects, objNum: ref.num) else {
                    throw PDFWriterError.malformedPDF
                }
                let merged = insertFont(intoResources: resDict, fontEntry: fontEntry)
                emit(ref.num, resGen, merged)
                // page keeps its /Resources ref → nothing else to change
            } else {
                throw PDFWriterError.malformedPDF
            }
        } else {
            dict = insertIntoDict(dict, entry: "/Resources << /Font << \(fontEntry) >> >>")
        }
        return dict
    }

    /// Add `fontEntry` to a `<< … >>` resources dict, merging into an existing inline `/Font`.
    private static func insertFont(intoResources res: String, fontEntry: String) -> String {
        if let font = topLevelValue(of: "Font", in: res), font.text.hasPrefix("<<") {
            var r = res
            let inner = String(font.text.dropFirst(2).dropLast(2))
            let merged = "<< \(inner.trimmingCharacters(in: .whitespacesAndNewlines)) \(fontEntry) >>"
            r.replaceSubrange(font.range, with: merged)
            return r
        }
        // No inline /Font (image-only scans, the common case) — or /Font is a ref we leave be
        // and simply add ours alongside under the same key namespace.
        return insertIntoDict(res, entry: "/Font << \(fontEntry) >>")
    }

    /// Insert `entry` immediately after the opening `<<` of a dict string.
    private static func insertIntoDict(_ dict: String, entry: String) -> String {
        guard let open = dict.range(of: "<<") else { return dict }
        var d = dict
        d.replaceSubrange(open, with: "<< \(entry) ")
        return d
    }

    // MARK: - Minimal PDF parsing

    /// Enumerate top-level `N G obj` headers → latest byte offset + generation, skipping bytes
    /// inside `stream … endstream` so binary payloads never yield phantom objects.
    static func indexTopLevelObjects(_ bytes: [UInt8]) throws -> [Int: (offset: Int, gen: Int)] {
        var result: [Int: (offset: Int, gen: Int)] = [:]
        let streamRanges = streamBodyRanges(bytes)
        var rangeIter = streamRanges.makeIterator()
        var nextRange = rangeIter.next()

        let objKW: [UInt8] = Array("obj".utf8)
        var i = 0
        let n = bytes.count
        while i < n {
            // Skip past any stream body we've entered.
            if let r = nextRange, i >= r.lowerBound {
                i = r.upperBound
                nextRange = rangeIter.next()
                continue
            }
            if bytes[i] == objKW[0], matches(bytes, at: i, objKW),
               isDelimiterOrSpace(bytes, before: i), isDelimiterOrSpace(bytes, at: i + 3) {
                // Backtrack across "  <gen> <num>".
                if let header = parseObjHeaderBackwards(bytes, objAt: i) {
                    result[header.num] = (header.start, header.gen)   // later offset wins
                }
            }
            i += 1
        }
        if result.isEmpty { throw PDFWriterError.malformedPDF }
        return result
    }

    /// Byte ranges [start-of-body, end-of-body) for every `stream … endstream`.
    private static func streamBodyRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let streamKW: [UInt8] = Array("stream".utf8)
        let endKW: [UInt8] = Array("endstream".utf8)
        var i = 0
        let n = bytes.count
        while i < n {
            if bytes[i] == streamKW[0], matches(bytes, at: i, streamKW) {
                // "stream" but not the tail of "endstream".
                if i >= 3, matches(bytes, at: i - 3, Array("end".utf8)) { i += 1; continue }
                var bodyStart = i + streamKW.count
                if bodyStart < n, bytes[bodyStart] == 0x0D { bodyStart += 1 }   // CR
                if bodyStart < n, bytes[bodyStart] == 0x0A { bodyStart += 1 }   // LF
                if let end = find(endKW, in: bytes, from: bodyStart) {
                    ranges.append(bodyStart..<end)
                    i = end + endKW.count
                    continue
                } else {
                    break   // malformed; stop skipping
                }
            }
            i += 1
        }
        return ranges
    }

    private struct ObjHeader { let num: Int; let gen: Int; let start: Int }

    /// From an `obj` keyword at `objAt`, read the preceding `<num> <gen>` and the header's start.
    private static func parseObjHeaderBackwards(_ bytes: [UInt8], objAt: Int) -> ObjHeader? {
        var j = objAt - 1
        func skipWS() { while j >= 0, isWhitespace(bytes[j]) { j -= 1 } }
        func readInt() -> (value: Int, start: Int)? {
            var end = j
            while j >= 0, bytes[j] >= 0x30, bytes[j] <= 0x39 { j -= 1 }
            let start = j + 1
            guard start <= end else { return nil }
            let digits = String(bytes: bytes[start...end], encoding: .ascii) ?? ""
            guard let v = Int(digits) else { return nil }
            return (v, start)
        }
        skipWS()
        guard let gen = readInt() else { return nil }
        skipWS()
        guard let num = readInt() else { return nil }
        return ObjHeader(num: num.value, gen: gen.value, start: num.start)
    }

    /// The `/Root` reference: from the last classic `trailer`, else the latest `/Type /XRef`
    /// stream dict, else a scan for `/Type /Catalog`.
    static func findRoot(_ bytes: [UInt8],
                         objects: [Int: (offset: Int, gen: Int)]) throws -> (num: Int, gen: Int) {
        if let last = findLast(Array("trailer".utf8), in: bytes),
           let dictStart = find(Array("<<".utf8), in: bytes, from: last),
           let dictText = balancedDict(bytes, from: dictStart),
           let ref = topLevelValue(of: "Root", in: dictText).flatMap({ parseRef($0.text) }) {
            return ref
        }
        // XRef-stream file: the object carrying /Type /XRef holds /Root.
        var best: (num: Int, gen: Int)?
        var bestOffset = -1
        for (num, info) in objects {
            guard let (dict, _) = objectDictText(bytes, objects: objects, objNum: num) else { continue }
            if topLevelName(of: "Type", in: dict) == "XRef",
               let ref = topLevelValue(of: "Root", in: dict).flatMap({ parseRef($0.text) }),
               info.offset > bestOffset {
                best = ref; bestOffset = info.offset
            }
        }
        if let best { return best }
        // Last resort: the catalog object itself.
        for (num, _) in objects {
            guard let (dict, gen) = objectDictText(bytes, objects: objects, objNum: num) else { continue }
            if topLevelName(of: "Type", in: dict) == "Catalog" { return (num, gen) }
        }
        throw PDFWriterError.malformedPDF
    }

    /// Ordered leaf page object numbers, walking `/Root → /Pages → /Kids`.
    static func orderedPageObjects(_ bytes: [UInt8],
                                   objects: [Int: (offset: Int, gen: Int)],
                                   root: (num: Int, gen: Int)) throws -> [Int] {
        guard let (catalog, _) = objectDictText(bytes, objects: objects, objNum: root.num),
              let pagesRef = topLevelValue(of: "Pages", in: catalog).flatMap({ parseRef($0.text) }) else {
            throw PDFWriterError.malformedPDF
        }
        var pages: [Int] = []
        var visited = Set<Int>()
        func walk(_ objNum: Int) throws {
            guard !visited.contains(objNum) else { return }
            visited.insert(objNum)
            guard let (dict, _) = objectDictText(bytes, objects: objects, objNum: objNum) else {
                throw PDFWriterError.unsupportedStructure   // not top-level → likely in an ObjStm
            }
            let type = topLevelName(of: "Type", in: dict)
            if type == "Page" {
                pages.append(objNum)
            } else if let kids = topLevelValue(of: "Kids", in: dict) {
                for ref in parseRefArray(kids.text) { try walk(ref.num) }
            } else if type == "Pages" {
                // /Pages with no /Kids — nothing to add
            } else {
                pages.append(objNum)   // untyped leaf
            }
        }
        try walk(pagesRef.num)
        guard !pages.isEmpty else { throw PDFWriterError.malformedPDF }
        return pages
    }

    /// The dict text (`<< … >>`) and generation of a top-level object, or nil if it isn't one.
    static func objectDictText(_ bytes: [UInt8],
                               objects: [Int: (offset: Int, gen: Int)],
                               objNum: Int) -> (String, Int)? {
        guard let info = objects[objNum] else { return nil }
        guard let dictStart = find(Array("<<".utf8), in: bytes, from: info.offset),
              let dict = balancedDict(bytes, from: dictStart) else { return nil }
        return (dict, info.gen)
    }

    /// The offset written by the file's final `startxref` (the previous xref, for `/Prev`).
    static func lastStartxref(_ bytes: [UInt8]) throws -> Int {
        guard let sx = findLast(Array("startxref".utf8), in: bytes) else {
            throw PDFWriterError.malformedPDF
        }
        var i = sx + "startxref".count
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
        var digits = ""
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { digits.unicodeScalars.append(UnicodeScalar(bytes[i])); i += 1 }
        guard let v = Int(digits) else { throw PDFWriterError.malformedPDF }
        return v
    }

    /// A classic xref section covering the appended/superseded objects, split into contiguous
    /// subsections (non-contiguous object numbers need multiple `first count` headers).
    private static func xrefSection(offsets: [Int: (offset: Int, gen: Int)]) -> String {
        let nums = offsets.keys.sorted()
        var s = "xref\n"
        var i = 0
        while i < nums.count {
            var j = i
            while j + 1 < nums.count, nums[j + 1] == nums[j] + 1 { j += 1 }
            let first = nums[i], count = j - i + 1
            s += "\(first) \(count)\n"
            for k in i...j {
                let e = offsets[nums[k]]!
                s += String(format: "%010ld %05ld n\r\n", e.offset, e.gen)
            }
            i = j + 1
        }
        return s
    }

    // MARK: - Dict value scanning (page/resources/font dicts are ASCII)

    /// A value token for `/key` at the top level of a `<< … >>` dict, with its range in `dict`.
    private static func topLevelValue(of key: String, in dict: String) -> (text: String, range: Range<String.Index>)? {
        let chars = Array(dict)
        let target = Array("/\(key)")
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" && i + 1 < chars.count && chars[i + 1] == "<" { depth += 1; i += 2; continue }
            if c == ">" && i + 1 < chars.count && chars[i + 1] == ">" { depth -= 1; i += 2; continue }
            // match /key only at the dict's own level (depth 1 within the outer <<)
            if depth == 1, c == "/", matchesChars(chars, at: i, target),
               isNameBoundary(chars, at: i + target.count) {
                var v = i + target.count
                while v < chars.count, chars[v] == " " || chars[v] == "\n" || chars[v] == "\r" || chars[v] == "\t" { v += 1 }
                let start = v
                let end = valueEnd(chars, from: v)
                let text = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rStart = dict.index(dict.startIndex, offsetBy: start)
                let rEnd = dict.index(dict.startIndex, offsetBy: end)
                return (text, rStart..<rEnd)
            }
            i += 1
        }
        return nil
    }

    private static func topLevelName(of key: String, in dict: String) -> String? {
        guard let v = topLevelValue(of: key, in: dict)?.text, v.hasPrefix("/") else { return nil }
        return String(v.dropFirst())
    }

    /// End index of a value beginning at `from`: handles `<<…>>`, `[…]`, `(…)`, `/name`,
    /// references `N G R`, and bare numbers/keywords.
    private static func valueEnd(_ chars: [Character], from: Int) -> Int {
        guard from < chars.count else { return from }
        switch chars[from] {
        case "<" where from + 1 < chars.count && chars[from + 1] == "<":
            var depth = 0, i = from
            while i < chars.count {
                if chars[i] == "<" && i + 1 < chars.count && chars[i + 1] == "<" { depth += 1; i += 2; continue }
                if chars[i] == ">" && i + 1 < chars.count && chars[i + 1] == ">" { depth -= 1; i += 2; if depth == 0 { return i }; continue }
                i += 1
            }
            return chars.count
        case "[":
            var depth = 0, i = from
            while i < chars.count {
                if chars[i] == "[" { depth += 1 }
                else if chars[i] == "]" { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return chars.count
        case "(":
            var depth = 0, i = from
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "(" { depth += 1 }
                else if chars[i] == ")" { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return chars.count
        default:
            // A reference `N G R`, a bare number, or a keyword (true/false/null). Read
            // whitespace-separated tokens, stopping after an `R` (reference), at the next
            // delimiter, or after a lone non-numeric keyword.
            func isSpace(_ c: Character) -> Bool { c == " " || c == "\n" || c == "\r" || c == "\t" }
            var i = from
            while i < chars.count {
                while i < chars.count, isSpace(chars[i]) { i += 1 }
                guard i < chars.count else { break }
                let c = chars[i]
                if c == "/" || c == ">" || c == "]" || c == "[" || c == "<" || c == "(" { break }
                let tokStart = i
                while i < chars.count, !isSpace(chars[i]), !"/><[(]".contains(chars[i]) { i += 1 }
                let tok = String(chars[tokStart..<i])
                if tok == "R" { break }                      // end of a reference
                if Int(tok) == nil && Double(tok) == nil { break }   // a keyword → single-token value
                // a number → may be the N or G of an "N G R" reference; keep reading
            }
            return i
        }
    }

    private static func parseRef(_ text: String) -> (num: Int, gen: Int)? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        guard parts.count >= 3, parts[2] == "R", let num = Int(parts[0]), let gen = Int(parts[1]) else { return nil }
        return (num, gen)
    }

    private static func parseRefArray(_ text: String) -> [(num: Int, gen: Int)] {
        let inner = text.hasPrefix("[") ? String(text.dropFirst().dropLast()) : text
        let toks = inner.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).map(String.init)
        var refs: [(Int, Int)] = []
        var i = 0
        while i + 2 < toks.count + 1 {
            if i + 2 < toks.count, toks[i + 2] == "R", let n = Int(toks[i]), let g = Int(toks[i + 1]) {
                refs.append((n, g)); i += 3
            } else { i += 1 }
        }
        return refs
    }

    /// Extract a balanced `<< … >>` starting at `from` as a Latin-1 string.
    private static func balancedDict(_ bytes: [UInt8], from: Int) -> String? {
        var depth = 0, i = from
        let n = bytes.count
        while i < n {
            if bytes[i] == 0x3C, i + 1 < n, bytes[i + 1] == 0x3C { depth += 1; i += 2; continue }   // <<
            if bytes[i] == 0x3E, i + 1 < n, bytes[i + 1] == 0x3E { depth -= 1; i += 2; if depth == 0 { return String(bytes: bytes[from..<i], encoding: .isoLatin1) }; continue }   // >>
            i += 1
        }
        return nil
    }

    // MARK: - byte helpers

    private static func matches(_ bytes: [UInt8], at i: Int, _ pat: [UInt8]) -> Bool {
        guard i + pat.count <= bytes.count else { return false }
        for k in 0..<pat.count where bytes[i + k] != pat[k] { return false }
        return true
    }

    private static func matchesChars(_ chars: [Character], at i: Int, _ pat: [Character]) -> Bool {
        guard i + pat.count <= chars.count else { return false }
        for k in 0..<pat.count where chars[i + k] != pat[k] { return false }
        return true
    }

    private static func isNameBoundary(_ chars: [Character], at i: Int) -> Bool {
        guard i < chars.count else { return true }
        let c = chars[i]
        return c == " " || c == "\n" || c == "\r" || c == "\t" || c == "/" || c == "[" || c == "<" || c == "(" || c == ">"
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0], matches(hay, at: i, needle) { return i }
            i += 1
        }
        return nil
    }

    private static func findLast(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i] == needle[0], matches(hay, at: i, needle) { return i }
            i -= 1
        }
        return nil
    }

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00
    }

    private static func isDelimiterOrSpace(_ bytes: [UInt8], at i: Int) -> Bool {
        guard i < bytes.count else { return true }
        return isWhitespace(bytes[i]) || bytes[i] == 0x3C || bytes[i] == 0x5B || bytes[i] == 0x2F
    }

    private static func isDelimiterOrSpace(_ bytes: [UInt8], before i: Int) -> Bool {
        guard i - 1 >= 0 else { return true }
        return isWhitespace(bytes[i - 1])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Encode an ASCII/Latin-1 PDF fragment to bytes losslessly (1 byte per scalar).
private func latin1(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }
