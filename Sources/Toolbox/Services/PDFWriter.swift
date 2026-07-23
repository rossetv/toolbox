// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
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
    /// A page (or the catalog) we must supersede lives in a structure this writer cannot read —
    /// an object stream with a filter it does not implement, or an object that resolves nowhere.
    /// The file fails inline so the batch continues (spec R2-N3).
    case unsupportedStructure
    /// The input exceeds the per-job bound. Fails that file inline rather than letting one job
    /// consume the machine.
    case inputTooLarge

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "The PDF could not be read."
        case .malformedPDF: return "The PDF structure could not be parsed."
        case .unsupportedStructure:
            return "This PDF uses a compressed object layout that OCR cannot amend."
        case .inputTooLarge: return "The PDF is too large for OCR to process safely."
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
/// Locating the page objects uses a byte-level scan (`PDFSyntax`) rather than a full xref
/// parser, so classic-xref, cross-reference-stream and object-stream PDFs all work. Objects
/// packed into an `/ObjStm` are superseded by emitting an **uncompressed top-level object of the
/// same number** — the newest cross-reference entry wins (PDF 32000-1 §7.5.6), so the object
/// stream itself never has to be rewritten.
///
/// Non-Latin scripts: the layer uses base-14 Helvetica + WinAnsi, which extracts ASCII/Latin
/// text. CJK/Arabic would need an embedded font + `/ToUnicode` CMap — a conscious v1 deferral.
struct PDFWriter {

    // MARK: - Structural limits
    //
    // Bounds on what the writer will accept from an untrusted file. Each exists because the
    // unbounded version is reachable from a crafted input: a page tree that is a linear chain of
    // 100k `/Pages` nodes overflows the stack, and a nesting depth of thousands does the same
    // through the dictionary scanners.

    /// Deepest `/Kids` nesting walked before the file is called malformed.
    static let maxPageTreeDepth = 256
    /// Most page-tree nodes visited before the file is called malformed. Well clear of the
    /// 1000-page scans the tool targets.
    static let maxPageTreeNodes = 500_000
    /// Most top-level objects indexed. The index is the one structure that grows with the file
    /// rather than with the page count: two gigabytes of `1 0 obj<<>>endobj` is a hundred
    /// million entries, so without a ceiling the *index* becomes the memory exhaustion.
    static let maxObjects = 5_000_000
    /// Largest input this writer will accept. See `appendTextLayer` for the whole bound.
    static let maxInputBytes = 2 << 30                 // 2 GiB

    /// Append the text layer, holding **no full copy of the input in memory**.
    ///
    /// This is the OCR path's per-job memory bound, and it is a set of four cooperating limits
    /// rather than one number, because the in-process path has no child to put a cap on:
    ///
    /// 1. The input is *memory-mapped*, not read — the kernel pages it in and evicts it under
    ///    pressure, so parsing a 500 MB scan costs no resident copy.
    /// 2. The output is *streamed* — the mapped original is copied to the destination in bounded
    ///    chunks and the appended section written after it, so the writer never materialises the
    ///    file a second (or third) time to grow it.
    /// 3. The object index is bounded by `maxObjects`, the page walk by `maxPageTreeDepth` and
    ///    `maxPageTreeNodes` — the allocations that scale with a *hostile* file rather than an
    ///    honest one.
    /// 4. `maxInputBytes` is the backstop for everything not enumerated above.
    ///
    /// It previously held about three copies at once: `Data(contentsOf:)`, a separate `[UInt8]`,
    /// and the grown output buffer. With `OCRViewModel`'s two concurrent jobs that is six times
    /// the file size resident, which on a large scan is a jetsam kill that takes every other
    /// queued job with it.
    func appendTextLayer(to input: URL,
                         output: URL,
                         pageText: [Int: [PositionedText]],
                         geometry: [Int: PageGeometry]) throws {
        guard let data = try? Data(contentsOf: input, options: .mappedIfSafe) else {
            throw PDFWriterError.cannotRead
        }
        guard data.count <= Self.maxInputBytes else { throw PDFWriterError.inputTooLarge }

        // Pages that actually carry recognised text.
        let targets = pageText.filter { !$0.value.isEmpty }.keys.sorted()
        guard !targets.isEmpty else {
            // Nothing to add — emit the original bytes verbatim (a valid no-op output).
            try Self.stream(data, to: output)
            return
        }

        // Parse inside the mapping. `UnsafeRawBufferPointer` is always zero-based, which keeps
        // every offset in the parser unambiguous.
        let appended = try data.withUnsafeBytes { raw in
            try Self.buildIncrementalSection(raw.bindMemory(to: UInt8.self),
                                             baseLength: data.count,
                                             targets: targets,
                                             pageText: pageText,
                                             geometry: geometry)
        }
        try Self.stream(data, to: output, appending: appended)
    }

    /// Write the mapped original to `output` in bounded chunks, then `extra`.
    private static func stream(_ data: Data, to output: URL, appending extra: Data = Data()) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
        _ = manager.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let chunk = 1 << 22                            // 4 MiB
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunk, data.endIndex)
            try handle.write(contentsOf: data[offset..<end])
            offset = end
        }
        if !extra.isEmpty { try handle.write(contentsOf: extra) }
    }

    /// Everything appended after the original bytes: the new objects, the new xref section and
    /// the trailer. Split out from `appendTextLayer` so the whole parse runs against one byte
    /// buffer and returns only the (small) bytes to append.
    static func buildIncrementalSection<C: RandomAccessCollection>(
        _ bytes: C,
        baseLength: Int,
        targets: [Int],
        pageText: [Int: [PositionedText]],
        geometry: [Int: PageGeometry]) throws -> Data
    where C.Element == UInt8, C.Index == Int {

        let topLevel = try indexTopLevelObjects(bytes)
        let index = ObjectIndex(topLevel: topLevel,
                                packed: indexObjectStreams(bytes, topLevel: topLevel))
        let root = try findRoot(bytes, objects: index)
        let pageObjs = try orderedPageObjects(bytes, objects: index, root: root)

        // Allocate above every object number the file could already be using — including any
        // the scan failed to reach, which the trailer's `/Size` still accounts for. Allocating
        // into a number that already exists would make the appended xref silently replace a
        // live object.
        var maxObj = max(index.highestObjectNumber, (trailerSize(bytes, objects: index) ?? 1) - 1)
        // Every object number reaching this point came through `PDFSyntax.parseInt`, which
        // refuses anything above `maxPlausibleInteger`; the check makes the invariant explicit
        // so `allocate()` can never trap on overflow.
        guard maxObj >= 0, maxObj <= PDFSyntax.maxPlausibleInteger else {
            throw PDFWriterError.malformedPDF
        }
        func allocate() -> Int { maxObj += 1; return maxObj }

        // One shared Helvetica font object for every appended layer.
        let fontObj = allocate()
        let fontName = "PDFTBox"   // resource key; unlikely to collide with a scan's resources

        // Accumulate appended objects; record each object's byte offset in the output.
        var appended = Data()
        appended.append(0x0A)   // separate from the original's trailing %%EOF
        var offsets: [Int: (offset: Int, gen: Int)] = [:]

        func emit(objNum: Int, gen: Int, body: [UInt8]) {
            offsets[objNum] = (baseLength + appended.count, gen)
            appended.append(contentsOf: latin1("\(objNum) \(gen) obj\n"))
            appended.append(contentsOf: body)
            appended.append(contentsOf: latin1("\nendobj\n"))
        }

        // Font object.
        emit(objNum: fontObj, gen: 0,
             body: latin1("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))

        for pageIndex in targets {
            // The byte-level page walk must agree with the indices recognition produced. Skipping
            // a missing one would silently discard that page's text — and if the walk merely
            // ORDERED pages differently, the text would land on the wrong page — while the job
            // still reported success. Decline the file so the caller can fall back instead.
            guard let objNum = pageObjs[safe: pageIndex] else {
                throw PDFWriterError.unsupportedStructure
            }
            guard let geo = geometry[pageIndex] else { throw PDFWriterError.malformedPDF }
            let boxes = pageText[pageIndex] ?? []

            guard let page = objectDict(bytes, objects: index, objNum: objNum) else {
                throw PDFWriterError.malformedPDF
            }

            // Build the invisible-text content stream for this page.
            let contentObj = allocate()
            let content = contentStream(for: boxes, geometry: geo, fontResource: fontName)
            let contentBody = latin1(content)
            emit(objNum: contentObj, gen: 0,
                 body: latin1("<< /Length \(contentBody.count) >>\nstream\n") + contentBody
                     + latin1("\nendstream"))

            // Supersede the page dict: append our content ref, ensure our font in /Resources.
            let newPageDict = try superseded(pageDict: page.bytes,
                                             addContent: contentObj,
                                             fontResource: fontName,
                                             fontObj: fontObj,
                                             bytes: bytes,
                                             objects: index,
                                             emit: { emit(objNum: $0, gen: $1, body: $2) })
            emit(objNum: objNum, gen: page.gen, body: newPageDict)
        }

        // The new cross-reference section must be **the same form the file already uses**. A
        // classic table appended to a cross-reference-stream document is not readable: PDFKit
        // refuses the result outright (verified against an object-stream fixture), so such a
        // document gets a cross-reference stream back.
        let prev = try lastStartxref(bytes)
        let xrefOffset = baseLength + appended.count

        if usesCrossReferenceStream(bytes, lastXref: prev) {
            // The stream is itself an indirect object, so it appears in its own table.
            let xrefObj = allocate()
            offsets[xrefObj] = (xrefOffset, 0)
            appended.append(contentsOf: crossReferenceStream(objNum: xrefObj, offsets: offsets,
                                                             root: root, prev: prev,
                                                             size: max(xrefObj, maxObj) + 1))
        } else {
            appended.append(contentsOf: latin1(xrefSection(offsets: offsets)))
            let size = (offsets.keys.max() ?? maxObj) + 1
            appended.append(contentsOf: latin1(
                "trailer\n<< /Size \(size) /Root \(root.num) \(root.gen) R /Prev \(prev) >>\n"))
        }
        appended.append(contentsOf: latin1("startxref\n\(xrefOffset)\n%%EOF\n"))
        return appended
    }

    /// Whether the file's most recent cross-reference section is a stream rather than a classic
    /// `xref` table.
    ///
    /// Decided by looking at the section `startxref` actually points at, which is the only
    /// authoritative answer: a hybrid-reference file contains both forms, and only the one the
    /// trailer chain leads to says which the producer meant.
    static func usesCrossReferenceStream<C: RandomAccessCollection>(_ b: C, lastXref: Int) -> Bool
    where C.Element == UInt8, C.Index == Int {
        guard lastXref >= b.startIndex, lastXref < b.endIndex else { return false }
        return !PDFSyntax.isKeyword(b, at: PDFSyntax.skipSpace(b, from: lastXref), Array("xref".utf8))
    }

    /// A cross-reference **stream** (PDF 32000-1 §7.5.8) covering the appended objects, carrying
    /// the trailer fields in its own dictionary.
    ///
    /// Left uncompressed: a `/Filter` is optional here, the table is a few dozen bytes, and one
    /// less encoded thing in the output is one less thing to get wrong.
    private static func crossReferenceStream(objNum: Int,
                                             offsets: [Int: (offset: Int, gen: Int)],
                                             root: (num: Int, gen: Int),
                                             prev: Int,
                                             size: Int) -> [UInt8] {
        let nums = offsets.keys.sorted()

        // Field 2 holds a byte offset, so it must be wide enough for the largest one.
        let largest = offsets.values.map(\.offset).max() ?? 0
        var offsetWidth = 1
        while offsetWidth < 8, largest >= (1 << (8 * offsetWidth)) { offsetWidth += 1 }

        var index = ""
        var table: [UInt8] = []
        var i = 0
        while i < nums.count {
            var j = i
            while j + 1 < nums.count, nums[j + 1] == nums[j] + 1 { j += 1 }
            index += "\(nums[i]) \(j - i + 1) "
            for k in i...j {
                let entry = offsets[nums[k]]!
                table.append(1)                                    // type 1: in use, at an offset
                for shift in stride(from: offsetWidth - 1, through: 0, by: -1) {
                    table.append(UInt8((entry.offset >> (8 * shift)) & 0xFF))
                }
                table.append(UInt8((entry.gen >> 8) & 0xFF))
                table.append(UInt8(entry.gen & 0xFF))
            }
            i = j + 1
        }

        var out = latin1("\(objNum) 0 obj\n")
        out += latin1("<< /Type /XRef /Size \(size) /Root \(root.num) \(root.gen) R /Prev \(prev)"
                    + " /W [ 1 \(offsetWidth) 2 ] /Index [ \(index.trimmingCharacters(in: .whitespaces)) ]"
                    + " /Length \(table.count) >>\nstream\n")
        out += table
        out += latin1("\nendstream\nendobj\n")
        return out
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
    ///
    /// Works on the dictionary's **bytes**. Splicing a `String` here would reintroduce the
    /// grapheme-cluster trap the byte scanners exist to avoid.
    static func superseded<C: RandomAccessCollection>(
        pageDict: [UInt8],
        addContent contentObj: Int,
        fontResource: String,
        fontObj: Int,
        bytes: C,
        objects: ObjectIndex,
        emit: (Int, Int, [UInt8]) -> Void) throws -> [UInt8]
    where C.Element == UInt8, C.Index == Int {
        var dict = pageDict

        // --- /Contents: make it an array ending in our content ref. ---
        let contentRef = "\(contentObj) 0 R"
        switch PDFSyntax.dictLookup(of: "Contents", in: dict, dictAt: 0) {
        case .found(let range):
            let value = Array(dict[range])
            let replacement: [UInt8]
            if value.first == 0x5B {                            // `[ a 0 R ]` → `[ a 0 R ours ]`
                // Only splice once the terminator is in sight. `PDFSyntax.endOfValue` returns the
                // end of the whole buffer for an unterminated array and still reports `.found`,
                // and `dropLast()` would then eat the enclosing dictionary's own bytes.
                guard value.last == 0x5D else { throw PDFWriterError.unsupportedStructure }
                let inner = trimmed(Array(value.dropFirst().dropLast()))
                replacement = latin1("[ ") + inner + latin1(" \(contentRef) ]")
            } else if let ref = PDFSyntax.parseRef(value) {
                // `/Contents 7 0 R` is legal when object 7 is a stream OR an array of streams.
                // Wrapping the array case gives `[ 7 0 R ours ]` — an array whose first element
                // references an array, a form the format does not define, and one no validator
                // here can see because our own layer still makes the page render with text.
                // A content stream resolves to a dictionary; anything else is the array case.
                guard objectDict(bytes, objects: objects, objNum: ref.num) != nil else {
                    throw PDFWriterError.unsupportedStructure
                }
                replacement = latin1("[ ") + value + latin1(" \(contentRef) ]")
            } else {
                // Neither an array nor a reference: `/Contents` cannot be a direct stream, so this
                // is malformed and not something to guess at.
                throw PDFWriterError.unsupportedStructure
            }
            dict.replaceSubrange(range, with: replacement)
        case .absent:
            dict = insertIntoDict(dict, entry: latin1("/Contents [ \(contentRef) ]"))
        case .unparseable:
            // Inserting a key into a dictionary we could not read risks duplicating a `/Contents`
            // that sits further along, past whatever defeated the scanner. A first-wins reader
            // then draws only our invisible layer and the page's real content vanishes.
            throw PDFWriterError.unsupportedStructure
        }

        // --- /Resources: ensure /Font << /<res> fontObj 0 R >>. ---
        let fontEntry = latin1("/\(fontResource) \(fontObj) 0 R")
        switch PDFSyntax.dictLookup(of: "Resources", in: dict, dictAt: 0) {
        case .found(let range):
            let value = Array(dict[range])
            if value.first == 0x3C {
                let merged = try insertFont(intoResources: value, fontEntry: fontEntry,
                                            bytes: bytes, objects: objects, emit: emit)
                dict.replaceSubrange(range, with: merged)
            } else if let ref = PDFSyntax.parseRef(value) {
                // Supersede the shared resources object, adding our font.
                guard let res = objectDict(bytes, objects: objects, objNum: ref.num) else {
                    throw PDFWriterError.malformedPDF
                }
                emit(ref.num, res.gen,
                     try insertFont(intoResources: res.bytes, fontEntry: fontEntry,
                                    bytes: bytes, objects: objects, emit: emit))
                // page keeps its /Resources ref → nothing else to change
            } else {
                throw PDFWriterError.malformedPDF
            }
        case .absent:
            if let entry = try inheritedResourcesEntry(pageDict: pageDict, fontEntry: fontEntry,
                                                       bytes: bytes, objects: objects, emit: emit) {
                dict = insertIntoDict(dict, entry: entry)
            }
        case .unparseable:
            throw PDFWriterError.unsupportedStructure
        }
        return dict
    }

    /// Place our font for a page that carries no `/Resources` of its own.
    ///
    /// `/Resources` is an **inheritable** page attribute (PDF 32000-1 Table 30): a page omitting it
    /// inherits the nearest ancestor's. Writing a page-level `/Resources` holding only our font
    /// would shadow that inherited dictionary, so every `/XObject`, `/Font` and `/ColorSpace` the
    /// page's own content stream names would stop resolving — the scan renders blank while OCR
    /// reports success. That is the worst failure this writer can have: silent, and it passes
    /// validation.
    ///
    /// Returns the entry to insert into the page dict, or nil when the font was instead added to
    /// the shared resources object the page already inherits.
    private static func inheritedResourcesEntry<C: RandomAccessCollection>(
        pageDict: [UInt8],
        fontEntry: [UInt8],
        bytes: C,
        objects: ObjectIndex,
        emit: (Int, Int, [UInt8]) -> Void) throws -> [UInt8]?
    where C.Element == UInt8, C.Index == Int {
        var node = pageDict
        // Bounded like every other tree walk here: a cyclic `/Parent` chain must not spin.
        for depth in 0..<maxPageTreeDepth {
            guard case .found(let parentRange) = PDFSyntax.dictLookup(of: "Parent", in: node, dictAt: 0),
                  let parent = PDFSyntax.parseRef(Array(node[parentRange])) else {
                // Reaching the top of the tree without finding `/Resources` anywhere means there
                // is genuinely nothing to inherit, so our own dictionary shadows nothing.
                //
                // A PAGE with no `/Parent` at all is a different animal. `/Parent` is required
                // (Table 30), but the input is untrusted and a reader that descends through
                // `/Kids` still resolves inherited resources for such a page — so we cannot prove
                // what it inherits, and guessing is how the shadowing bug happened.
                guard depth > 0 else { throw PDFWriterError.unsupportedStructure }
                return latin1("/Resources << /Font << ") + fontEntry + latin1(" >> >>")
            }
            guard let ancestor = objectDict(bytes, objects: objects, objNum: parent.num) else {
                throw PDFWriterError.unsupportedStructure
            }
            switch PDFSyntax.dictLookup(of: "Resources", in: ancestor.bytes, dictAt: 0) {
            case .found(let range):
                let value = Array(ancestor.bytes[range])
                if value.first == 0x3C {
                    // Inherited as an inline dict: give the page its own copy with ours merged in.
                    // A page-level dict overrides the inherited one, and this copy carries
                    // everything the inherited one carried.
                    let merged = try insertFont(intoResources: value, fontEntry: fontEntry,
                                                bytes: bytes, objects: objects, emit: emit)
                    return latin1("/Resources ") + merged
                }
                if let ref = PDFSyntax.parseRef(value) {
                    // Inherited by reference: add our font to the shared object itself, so every
                    // page inheriting it keeps exactly the resources it already had.
                    guard let res = objectDict(bytes, objects: objects, objNum: ref.num) else {
                        throw PDFWriterError.unsupportedStructure
                    }
                    emit(ref.num, res.gen,
                         try insertFont(intoResources: res.bytes, fontEntry: fontEntry,
                                        bytes: bytes, objects: objects, emit: emit))
                    return nil
                }
                throw PDFWriterError.unsupportedStructure
            case .absent:
                node = ancestor.bytes                          // keep walking up the tree
            case .unparseable:
                throw PDFWriterError.unsupportedStructure
            }
        }
        throw PDFWriterError.unsupportedStructure
    }

    /// Add `fontEntry` to a `<< … >>` resources dict, merging into an existing `/Font`.
    ///
    /// `/Font` may be inline or an indirect reference. Adding a second `/Font` key alongside an
    /// existing one leaves the dictionary with duplicate keys, which PDF 32000-1 §7.3.7 forbids
    /// and readers resolve arbitrarily — a first-wins reader would see only our Helvetica and lose
    /// every font the page actually uses, so its visible text stops rendering.
    private static func insertFont<C: RandomAccessCollection>(
        intoResources res: [UInt8],
        fontEntry: [UInt8],
        bytes: C,
        objects: ObjectIndex,
        emit: (Int, Int, [UInt8]) -> Void) throws -> [UInt8]
    where C.Element == UInt8, C.Index == Int {
        switch PDFSyntax.dictLookup(of: "Font", in: res, dictAt: 0) {
        case .found(let range):
            let value = Array(res[range])
            if value.count >= 4, value[0] == 0x3C, value[1] == 0x3C {
                // Same rule as the `/Contents` array: an unterminated dictionary still reports
                // `.found`, and `dropLast(2)` would then consume the enclosing dict's own `>>`.
                guard value.suffix(2).elementsEqual([0x3E, 0x3E]) else {
                    throw PDFWriterError.unsupportedStructure
                }
                var r = res
                let inner = trimmed(Array(value.dropFirst(2).dropLast(2)))
                r.replaceSubrange(range, with: latin1("<< ") + inner + latin1(" ") + fontEntry + latin1(" >>"))
                return r
            }
            if let ref = PDFSyntax.parseRef(value) {
                // Indirect /Font: supersede the referenced dictionary with ours added, leaving the
                // resources dict pointing at the same object number.
                guard let font = objectDict(bytes, objects: objects, objNum: ref.num),
                      font.bytes.count >= 4, font.bytes[0] == 0x3C, font.bytes[1] == 0x3C else {
                    throw PDFWriterError.unsupportedStructure
                }
                let inner = trimmed(Array(font.bytes.dropFirst(2).dropLast(2)))
                emit(ref.num, font.gen, latin1("<< ") + inner + latin1(" ") + fontEntry + latin1(" >>"))
                return res
            }
            throw PDFWriterError.unsupportedStructure
        case .absent:
            // No /Font at all — the common case for an image-only scan.
            return insertIntoDict(res, entry: latin1("/Font << ") + fontEntry + latin1(" >>"))
        case .unparseable:
            throw PDFWriterError.unsupportedStructure
        }
    }

    /// Insert `entry` immediately after the opening `<<` of a dict.
    private static func insertIntoDict(_ dict: [UInt8], entry: [UInt8]) -> [UInt8] {
        guard dict.count >= 2, dict[0] == 0x3C, dict[1] == 0x3C else { return dict }
        var d = dict
        d.replaceSubrange(0..<2, with: latin1("<< ") + entry + latin1(" "))
        return d
    }

    private static func trimmed(_ b: [UInt8]) -> [UInt8] {
        var lo = 0, hi = b.count
        while lo < hi, PDFSyntax.isWhitespace(b[lo]) { lo += 1 }
        while hi > lo, PDFSyntax.isWhitespace(b[hi - 1]) { hi -= 1 }
        return Array(b[lo..<hi])
    }

    // MARK: - Object index

    /// One top-level `N G obj … endobj`, with the extent that bounds every scan for its content.
    struct IndexedObject: Equatable {
        let gen: Int
        /// First byte of the `N G obj` header.
        let headerStart: Int
        /// First byte after the `obj` keyword.
        let bodyStart: Int
        /// First byte of the closing `endobj` keyword.
        let bodyEnd: Int
    }

    /// Everything an object number can resolve against — the two places an object can live.
    struct ObjectIndex {
        /// Objects written as `N G obj … endobj` in the file itself.
        let topLevel: [Int: IndexedObject]
        /// Objects packed into a compressed object stream, as their dictionary bytes. A packed
        /// object always has generation 0 (PDF 32000-1 §7.5.7).
        let packed: [Int: [UInt8]]

        /// The highest object number the file uses, from either place.
        var highestObjectNumber: Int { max(topLevel.keys.max() ?? 0, packed.keys.max() ?? 0) }
    }

    private static let objKW = Array("obj".utf8)
    private static let endobjKW = Array("endobj".utf8)
    private static let streamKW = Array("stream".utf8)
    private static let endstreamKW = Array("endstream".utf8)

    /// Index every top-level `N G obj … endobj`, in one forward pass that honours PDF's lexical
    /// rules: comments, literal strings and hex strings are skipped, keywords must sit at token
    /// boundaries, and a stream body is skipped by its dictionary's `/Length`.
    ///
    /// Two things this pass deliberately gets right that a substring scan does not. `stream` is
    /// accepted only as a whole token that directly follows its own dictionary and is followed by
    /// an end-of-line, so the `stream` inside `/BaseFont /BitstreamVeraSans` cannot start a
    /// phantom stream body and swallow the object headers after it. And the body's extent comes
    /// from `/Length` wherever that is a usable direct integer, so an `endstream` byte sequence
    /// occurring *inside* attacker-controlled binary image data cannot end the skip early and let
    /// a planted `N G obj` override the file's real object of that number.
    static func indexTopLevelObjects<C: RandomAccessCollection>(_ b: C) throws -> [Int: IndexedObject]
    where C.Element == UInt8, C.Index == Int {
        var result: [Int: IndexedObject] = [:]
        var open: (num: Int, gen: Int, headerStart: Int, bodyStart: Int)?
        var dictStart: Int?
        var lastDict: Range<Int>?
        var depth = 0
        var i = b.startIndex
        let n = b.endIndex

        while i < n {
            switch b[i] {
            case 0x25:                                          // comment
                i = PDFSyntax.skipSpace(b, from: i)
            case 0x28:                                          // literal string
                i = PDFSyntax.endOfLiteralString(b, from: i)
            case 0x3C:
                if i + 1 < n, b[i + 1] == 0x3C {
                    if depth == 0 { dictStart = i }
                    depth += 1
                    i += 2
                } else {
                    i = PDFSyntax.endOfHexString(b, from: i)
                }
            case 0x3E where i + 1 < n && b[i + 1] == 0x3E:
                if depth > 0 { depth -= 1 }
                i += 2
                if depth == 0, let s = dictStart { lastDict = s..<i; dictStart = nil }
            case 0x73 where PDFSyntax.isKeyword(b, at: i, streamKW):
                if let d = lastDict, PDFSyntax.skipSpace(b, from: d.upperBound) == i,
                   let end = streamExtentEnd(b, dictAt: d.lowerBound, keywordEnd: i + streamKW.count) {
                    i = end
                } else {
                    i += streamKW.count
                }
            case 0x65 where PDFSyntax.isKeyword(b, at: i, endobjKW):
                if let o = open {
                    result[o.num] = IndexedObject(gen: o.gen, headerStart: o.headerStart,
                                                  bodyStart: o.bodyStart, bodyEnd: i)
                    guard result.count <= maxObjects else { throw PDFWriterError.malformedPDF }
                    open = nil
                }
                i += endobjKW.count
            case 0x6F where PDFSyntax.isKeyword(b, at: i, objKW):
                if let h = parseObjHeaderBackwards(b, objAt: i) {
                    open = (h.num, h.gen, h.start, i + objKW.count)
                }
                depth = 0
                dictStart = nil
                lastDict = nil
                i += objKW.count
            default:
                i += 1
            }
        }
        if result.isEmpty { throw PDFWriterError.malformedPDF }
        return result
    }

    /// The index just past `endstream` for the stream whose dictionary starts at `dictAt` and
    /// whose `stream` keyword ends at `keywordEnd`, or nil when this is not a stream at all.
    ///
    /// `/Length` is preferred and verified — if `endstream` really is where `/Length` says the
    /// body ends, the extent is trustworthy even for binary payloads. Files with a wrong or
    /// indirect `/Length` do exist, so the fallback is a *token-bounded* search for `endstream`.
    private static func streamExtentEnd<C: RandomAccessCollection>(
        _ b: C, dictAt: Int, keywordEnd: Int) -> Int?
    where C.Element == UInt8, C.Index == Int {
        // PDF 32000-1 §7.3.8.1: the keyword is followed by CRLF or LF (a lone CR is tolerated).
        var bodyStart = keywordEnd
        guard bodyStart < b.endIndex, b[bodyStart] == 0x0D || b[bodyStart] == 0x0A else { return nil }
        if b[bodyStart] == 0x0D { bodyStart += 1 }
        if bodyStart < b.endIndex, b[bodyStart] == 0x0A { bodyStart += 1 }

        if let length = PDFSyntax.dictInt(of: "Length", in: b, dictAt: dictAt),
           let bodyEnd = addingWithinBounds(bodyStart, length, limit: b.endIndex) {
            let after = PDFSyntax.skipSpace(b, from: bodyEnd)
            if PDFSyntax.isKeyword(b, at: after, endstreamKW) { return after + endstreamKW.count }
        }
        var j = bodyStart
        while j < b.endIndex {
            if b[j] == 0x65, PDFSyntax.isKeyword(b, at: j, endstreamKW) { return j + endstreamKW.count }
            j += 1
        }
        return nil
    }

    private static func addingWithinBounds(_ a: Int, _ b: Int, limit: Int) -> Int? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow, sum >= 0, sum <= limit else { return nil }
        return sum
    }

    /// From an `obj` keyword at `objAt`, read the preceding `N G` and the header's start.
    /// Object numbers beyond `PDFSyntax.maxPlausibleInteger` are refused here rather than parsed
    /// into `Int.max` and trapped on later.
    private static func parseObjHeaderBackwards<C: RandomAccessCollection>(
        _ b: C, objAt: Int) -> (num: Int, gen: Int, start: Int)?
    where C.Element == UInt8, C.Index == Int {
        var j = objAt - 1
        func skipWS() { while j >= b.startIndex, PDFSyntax.isWhitespace(b[j]) { j -= 1 } }
        func readIntBackwards() -> (value: Int, start: Int)? {
            let end = j
            while j >= b.startIndex, PDFSyntax.isDigit(b[j]) { j -= 1 }
            let start = j + 1
            guard start <= end, let v = PDFSyntax.parseInt(Array(b[start...end])) else { return nil }
            return (v, start)
        }
        skipWS()
        guard let gen = readIntBackwards() else { return nil }
        skipWS()
        guard let num = readIntBackwards() else { return nil }
        return (num.value, gen.value, num.start)
    }

    /// The dictionary bytes and generation of an object, from wherever it lives.
    ///
    /// A top-level definition wins outright: it can only be *later* in the file than the object
    /// stream's copy, and the newest definition of an object number is the live one.
    ///
    /// The top-level scan is bounded to the object's own `obj … endobj` extent, and required to
    /// *start* there: an unbounded forward search for `<<` runs straight into the next object and
    /// returns that object's dictionary attributed to this object number — from which a non-page
    /// object gets superseded with a page-shaped dictionary, or a bogus `/Root` is taken as the
    /// catalog.
    static func objectDict<C: RandomAccessCollection>(
        _ b: C, objects: ObjectIndex, objNum: Int) -> (bytes: [UInt8], gen: Int)?
    where C.Element == UInt8, C.Index == Int {
        if let info = objects.topLevel[objNum] {
            let start = PDFSyntax.skipSpace(b, from: info.bodyStart)
            guard start + 1 < info.bodyEnd, b[start] == 0x3C, b[start + 1] == 0x3C,
                  let end = PDFSyntax.endOfDictionary(b, from: start), end <= info.bodyEnd else {
                return nil
            }
            return (Array(b[start..<end]), info.gen)
        }
        guard let packed = objects.packed[objNum] else { return nil }
        return (packed, 0)
    }

    // MARK: - Compressed object streams

    /// Most bytes one `/ObjStm` may inflate to. A stream's compressed size says nothing about
    /// its expanded size, and the file is untrusted.
    static let maxObjectStreamBytes = 64 << 20        // 64 MiB

    /// Every object packed into an `/ObjStm`, keyed by object number.
    ///
    /// A compressed object stream holds whole objects, so a page or catalog living in one is not
    /// a top-level `N G obj` and the scan above cannot see it — which is why such files used to be
    /// refused outright, excluding about a fifth of a representative corpus from OCR.
    ///
    /// Superseding a packed object needs **no re-compression**: an uncompressed top-level
    /// `N 0 obj` in the appended section overrides the packed copy, because the newest
    /// cross-reference entry for an object number is the live one (PDF 32000-1 §7.5.6). Rewriting
    /// the object stream would be strictly harder and riskier for no benefit.
    ///
    /// Object streams this cannot read — an unsupported filter, a predictor, a truncated body —
    /// are skipped rather than fatal. If the skipped stream held an object the writer actually
    /// needed, that surfaces at the point of use as `.unsupportedStructure`; if it did not, the
    /// file OCRs fine and there is nothing to report.
    static func indexObjectStreams<C: RandomAccessCollection>(
        _ b: C, topLevel: [Int: IndexedObject]) -> [Int: [UInt8]]
    where C.Element == UInt8, C.Index == Int {
        var packed: [Int: [UInt8]] = [:]
        let bare = ObjectIndex(topLevel: topLevel, packed: [:])
        // A per-stream cap alone still lets a file with many object streams inflate without
        // bound, so the budget is spent across the whole file.
        var budget = maxObjectStreamBytes

        // Sorted, not dictionary order: Swift seeds its hasher per process, so once a file's
        // object streams exceed the budget below, *which* ones get indexed would otherwise vary
        // run to run — the same document would OCR on one launch and fail on the next.
        for num in topLevel.keys.sorted() where budget > 0 {
            guard let obj = objectDict(b, objects: bare, objNum: num),
                  PDFSyntax.dictName(of: "Type", in: obj.bytes, dictAt: 0) == "ObjStm",
                  isPlainFlate(obj.bytes),
                  let count = PDFSyntax.dictInt(of: "N", in: obj.bytes, dictAt: 0),
                  let first = PDFSyntax.dictInt(of: "First", in: obj.bytes, dictAt: 0),
                  count > 0, count <= maxObjects,
                  let body = streamBody(b, topLevel: topLevel, objNum: num),
                  let inflated = PDFFlate.inflate(b[body], limit: budget),
                  first <= inflated.count else { continue }
            budget -= inflated.count

            // The header is `N` pairs of `objectNumber offsetFromFirst`.
            var entries: [(num: Int, offset: Int)] = []
            var cursor = 0
            for _ in 0..<count {
                guard let numTok = PDFSyntax.readToken(inflated, from: cursor),
                      let packedNum = PDFSyntax.parseInt(numTok.bytes),
                      let offTok = PDFSyntax.readToken(inflated, from: numTok.end),
                      let offset = PDFSyntax.parseInt(offTok.bytes),
                      first + offset <= inflated.count else { break }
                entries.append((packedNum, first + offset))
                cursor = offTok.end
            }
            guard cursor <= first else { continue }   // the header must stay inside /First

            // Extents come from the *next* object's offset, so sort by offset first — nothing
            // requires the header to list them in order.
            entries.sort { $0.offset < $1.offset }
            for (i, entry) in entries.enumerated() {
                let end = i + 1 < entries.count ? entries[i + 1].offset : inflated.count
                let start = PDFSyntax.skipSpace(inflated, from: entry.offset)
                guard start + 1 < end, inflated[start] == 0x3C, inflated[start + 1] == 0x3C,
                      let dictEnd = PDFSyntax.endOfDictionary(inflated, from: start),
                      dictEnd <= end else { continue }        // not a dictionary — nothing to use
                packed[entry.num] = Array(inflated[start..<dictEnd])
            }
        }
        return packed
    }

    /// `/Filter /FlateDecode` with no `/DecodeParms` predictor. Anything else — an unimplemented
    /// filter, a filter chain, a PNG/TIFF predictor — is refused rather than mis-decoded.
    private static func isPlainFlate(_ dict: [UInt8]) -> Bool {
        guard PDFSyntax.dictName(of: "Filter", in: dict, dictAt: 0) == "FlateDecode" else { return false }
        guard let parms = PDFSyntax.dictValue(of: "DecodeParms", in: dict, dictAt: 0) else { return true }
        let inner = Array(dict[parms])
        guard inner.first == 0x3C else { return false }        // an indirect /DecodeParms: refuse
        let predictor = PDFSyntax.dictInt(of: "Predictor", in: inner, dictAt: 0) ?? 1
        return predictor <= 1
    }

    /// The byte range of a stream object's body, `/Length` preferred and verified.
    static func streamBody<C: RandomAccessCollection>(
        _ b: C, topLevel: [Int: IndexedObject], objNum: Int) -> Range<Int>?
    where C.Element == UInt8, C.Index == Int {
        guard let info = topLevel[objNum] else { return nil }
        let dictStart = PDFSyntax.skipSpace(b, from: info.bodyStart)
        guard dictStart + 1 < info.bodyEnd, b[dictStart] == 0x3C, b[dictStart + 1] == 0x3C,
              let dictEnd = PDFSyntax.endOfDictionary(b, from: dictStart) else { return nil }
        let keyword = PDFSyntax.skipSpace(b, from: dictEnd)
        guard PDFSyntax.isKeyword(b, at: keyword, streamKW) else { return nil }

        var start = keyword + streamKW.count
        guard start < b.endIndex, b[start] == 0x0D || b[start] == 0x0A else { return nil }
        if b[start] == 0x0D { start += 1 }
        if start < b.endIndex, b[start] == 0x0A { start += 1 }

        if let length = resolveLength(b, topLevel: topLevel, dictAt: dictStart),
           let end = addingWithinBounds(start, length, limit: b.endIndex),
           PDFSyntax.isKeyword(b, at: PDFSyntax.skipSpace(b, from: end), endstreamKW) {
            return start..<end
        }
        // A wrong or indirect-and-unresolvable `/Length` happens in the wild; recover by finding
        // the keyword, and drop the EOL the producer put before it.
        var j = start
        while j < b.endIndex {
            if b[j] == 0x65, PDFSyntax.isKeyword(b, at: j, endstreamKW) {
                var end = j
                if end > start, b[end - 1] == 0x0A { end -= 1 }
                if end > start, b[end - 1] == 0x0D { end -= 1 }
                return start..<end
            }
            j += 1
        }
        return nil
    }

    /// `/Length`, following one level of indirect reference.
    private static func resolveLength<C: RandomAccessCollection>(
        _ b: C, topLevel: [Int: IndexedObject], dictAt: Int) -> Int?
    where C.Element == UInt8, C.Index == Int {
        if let direct = PDFSyntax.dictInt(of: "Length", in: b, dictAt: dictAt) { return direct }
        guard let ref = PDFSyntax.dictRef(of: "Length", in: b, dictAt: dictAt),
              let info = topLevel[ref.num],
              let token = PDFSyntax.readToken(b, from: info.bodyStart),
              token.end <= info.bodyEnd else { return nil }
        return PDFSyntax.parseInt(token.bytes)
    }

    // MARK: - Document structure

    /// The `/Root` reference: from the last classic `trailer`, else the latest `/Type /XRef`
    /// stream dict, else a scan for `/Type /Catalog`.
    static func findRoot<C: RandomAccessCollection>(
        _ b: C, objects: ObjectIndex) throws -> (num: Int, gen: Int)
    where C.Element == UInt8, C.Index == Int {
        if let dictAt = lastTrailerDict(b), let ref = PDFSyntax.dictRef(of: "Root", in: b, dictAt: dictAt) {
            return ref
        }
        // XRef-stream file: the object carrying /Type /XRef holds /Root.
        if let xref = latestObject(b, objects: objects, ofType: "XRef"),
           let ref = PDFSyntax.dictRef(of: "Root", in: xref.dict, dictAt: 0) {
            return ref
        }
        // Last resort: the catalog object itself, which may be packed in an object stream.
        if let catalog = latestObject(b, objects: objects, ofType: "Catalog") {
            return (catalog.num, catalog.gen)
        }
        if let packed = objects.packed.first(where: {
            PDFSyntax.dictName(of: "Type", in: $0.value, dictAt: 0) == "Catalog"
        }) {
            return (packed.key, 0)
        }
        throw PDFWriterError.malformedPDF
    }

    /// `/Size` from the last classic trailer, else from the latest `/Type /XRef` stream dict.
    static func trailerSize<C: RandomAccessCollection>(
        _ b: C, objects: ObjectIndex) -> Int?
    where C.Element == UInt8, C.Index == Int {
        if let dictAt = lastTrailerDict(b), let size = PDFSyntax.dictInt(of: "Size", in: b, dictAt: dictAt) {
            return size
        }
        guard let xref = latestObject(b, objects: objects, ofType: "XRef") else { return nil }
        return PDFSyntax.dictInt(of: "Size", in: xref.dict, dictAt: 0)
    }

    /// Byte offset of the `<<` opening the file's last `trailer` dictionary.
    private static func lastTrailerDict<C: RandomAccessCollection>(_ b: C) -> Int?
    where C.Element == UInt8, C.Index == Int {
        let kw = Array("trailer".utf8)
        var i = b.endIndex - kw.count
        while i >= b.startIndex {
            if b[i] == 0x74, PDFSyntax.isKeyword(b, at: i, kw) {
                let d = PDFSyntax.skipSpace(b, from: i + kw.count)
                if d + 1 < b.endIndex, b[d] == 0x3C, b[d + 1] == 0x3C { return d }
                return nil
            }
            i -= 1
        }
        return nil
    }

    /// The latest-defined object whose dictionary declares `/Type /<type>`.
    private static func latestObject<C: RandomAccessCollection>(
        _ b: C, objects: ObjectIndex, ofType type: String) -> (num: Int, gen: Int, dict: [UInt8])?
    where C.Element == UInt8, C.Index == Int {
        var best: (num: Int, gen: Int, dict: [UInt8])?
        var bestOffset = -1
        for (num, info) in objects.topLevel where info.headerStart > bestOffset {
            guard let obj = objectDict(b, objects: objects, objNum: num),
                  PDFSyntax.dictName(of: "Type", in: obj.bytes, dictAt: 0) == type else { continue }
            best = (num, obj.gen, obj.bytes)
            bestOffset = info.headerStart
        }
        return best
    }

    /// Ordered leaf page object numbers, walking `/Root → /Pages → /Kids`.
    ///
    /// An explicit stack, not recursion: a page tree that is a linear chain of `/Pages` nodes is
    /// structurally valid PDF and a few megabytes long, and recursing it once per level overflows
    /// the stack and kills the process — taking every other job in the batch with it.
    static func orderedPageObjects<C: RandomAccessCollection>(
        _ b: C, objects: ObjectIndex, root: (num: Int, gen: Int)) throws -> [Int]
    where C.Element == UInt8, C.Index == Int {
        // A catalog that resolves *nowhere* is a structure this writer could not read — an
        // object stream it had to skip — not a malformed file. The distinction is what the user
        // is told, so keep it honest.
        guard let catalog = objectDict(b, objects: objects, objNum: root.num) else {
            throw PDFWriterError.unsupportedStructure
        }
        guard let pagesRef = PDFSyntax.dictRef(of: "Pages", in: catalog.bytes, dictAt: 0) else {
            throw PDFWriterError.malformedPDF
        }
        var pages: [Int] = []
        var visited = Set<Int>()
        var stack: [(num: Int, depth: Int)] = [(pagesRef.num, 0)]
        var nodes = 0

        while let node = stack.popLast() {
            guard !visited.contains(node.num) else { continue }
            visited.insert(node.num)
            nodes += 1
            guard node.depth <= maxPageTreeDepth, nodes <= maxPageTreeNodes else {
                throw PDFWriterError.malformedPDF
            }
            guard let obj = objectDict(b, objects: objects, objNum: node.num) else {
                throw PDFWriterError.unsupportedStructure   // not a top-level dict → likely an ObjStm
            }
            let type = PDFSyntax.dictName(of: "Type", in: obj.bytes, dictAt: 0)
            if type == "Page" {
                pages.append(node.num)
            } else if let kids = PDFSyntax.dictValue(of: "Kids", in: obj.bytes, dictAt: 0) {
                // Push in reverse so the stack yields the kids in document order.
                for ref in PDFSyntax.parseRefArray(Array(obj.bytes[kids])).reversed() {
                    stack.append((ref.num, node.depth + 1))
                }
            } else if type == "Pages" {
                // /Pages with no /Kids — nothing to add
            } else {
                pages.append(node.num)   // untyped leaf
            }
        }
        guard !pages.isEmpty else { throw PDFWriterError.malformedPDF }
        return pages
    }

    /// The offset written by the file's final `startxref` (the previous xref, for `/Prev`).
    static func lastStartxref<C: RandomAccessCollection>(_ b: C) throws -> Int
    where C.Element == UInt8, C.Index == Int {
        let kw = Array("startxref".utf8)
        var i = b.endIndex - kw.count
        while i >= b.startIndex {
            if b[i] == 0x73, PDFSyntax.isKeyword(b, at: i, kw) {
                guard let tok = PDFSyntax.readToken(b, from: i + kw.count),
                      let v = PDFSyntax.parseInt(tok.bytes) else { throw PDFWriterError.malformedPDF }
                return v
            }
            i -= 1
        }
        throw PDFWriterError.malformedPDF
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Encode an ASCII/Latin-1 PDF fragment to bytes losslessly (1 byte per scalar).
func latin1(_ s: String) -> [UInt8] { Array(s.data(using: .isoLatin1) ?? Data(s.utf8)) }
