// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import CoreGraphics

/// Per-page MRC eligibility. Two independent gates:
///  1. `structure(of:)` — cheap structural scan (R2): MRC may only touch pages that are one
///     image and nothing else, because the fallback path rasterises and rasterising text or
///     vector art is destruction, not compression.
///  2. `features(of:)`/`verdict(features:)` (Task 6) — signal measurement on one low-DPI render.
enum MRCClassifier {

    enum PageStructure: Equatable {
        case simpleSingleImage
        case complex
    }

    /// Scans the page's content stream operators. Exactly one image XObject draw, zero text
    /// blocks, zero path-painting operators → simple. Anything unexpected (scan failure,
    /// missing CGPDFPage, annotations, inherited-resources XObject dicts) is complex — fail
    /// closed, the gs path handles it properly.
    static func structure(of page: PDFPage) -> PageStructure {
        guard page.string?.isEmpty != false, page.annotations.isEmpty,
              let cgPage = page.pageRef else { return .complex }

        final class Counts {
            var images = 0
            var text = 0
            var paints = 0
        }
        let counts = Counts()
        guard let table = CGPDFOperatorTableCreate() else { return .complex }

        func register(_ op: String, _ callback: CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, op, callback)
        }

        register("Do") { _, info in
            Unmanaged<Counts>.fromOpaque(info!).takeUnretainedValue().images += 1
        }
        register("BI") { _, info in
            Unmanaged<Counts>.fromOpaque(info!).takeUnretainedValue().images += 1
        }
        register("BT") { _, info in
            Unmanaged<Counts>.fromOpaque(info!).takeUnretainedValue().text += 1
        }
        let paintOp: CGPDFOperatorCallback = { _, info in
            Unmanaged<Counts>.fromOpaque(info!).takeUnretainedValue().paints += 1
        }
        for paint in ["f", "F", "f*", "B", "B*", "b", "b*", "S", "s", "sh"] {
            register(paint, paintOp)
        }

        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counts).toOpaque())
        let ok = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        guard ok else { return .complex }

        // `Do` cannot distinguish image vs form XObjects from the operator alone; count the
        // page's own /Resources /XObject entries and require exactly one, of /Subtype /Image.
        // An inherited /Resources (declared on an ancestor Pages node, not this page dictionary)
        // is deliberately not chased — fail closed to `.complex`.
        guard singleImageXObject(cgPage) else { return .complex }
        return (counts.images == 1 && counts.text == 0 && counts.paints == 0) ? .simpleSingleImage : .complex
    }

    /// True iff the page dictionary's own (non-inherited) /Resources /XObject holds exactly one
    /// entry and it is /Subtype /Image.
    private static func singleImageXObject(_ page: CGPDFPage) -> Bool {
        guard let dict = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        guard CGPDFDictionaryGetCount(xobjects) == 1 else { return false }

        final class Box { var isImage = false }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { _, value, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream,
               let sdict = CGPDFStreamGetDictionary(stream) {
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(sdict, "Subtype", &subtype), let subtype {
                    box.isImage = String(cString: subtype) == "Image"
                }
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.isImage
    }

    // MARK: - Signals & verdict (Task 6)

    /// One ≈100 DPI render feeds both signals (spec R14: tens of ms per page).
    static let classifierDPI: CGFloat = 100

    /// The long-edge pixel dimension to render `page` at for classification.
    static func renderDimension(for page: PDFPage) -> CGFloat {
        let box = page.bounds(for: .mediaBox)
        return max(box.width, box.height) * classifierDPI / 72.0
    }

    // Conservative eligibility envelope; any doubt declines (R3). Values are M2-calibrated
    // starting points — deliberately not tuned to make fixtures pass.
    static let maxColourCoverage = 0.35
    static let maxMeanComponentSize = 220.0       // px² at the classifier's render scale
    static let minInkCoverage = 0.01
    static let maxInkCoverage = 0.35
    static let minComponentCount = 40

    /// Both signals from one RGBA buffer. Rows are addressed via `bytesPerRow` and only the real
    /// `width` is sampled — padding bytes are never read (C1: the odd-width regression proves it).
    static func features(of image: CGImage) -> MRCPageFeatures? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = ctx.bytesPerRow

        // Pass 1 — per-pixel: luminance histogram for an adaptive ink threshold, chroma count.
        var histogram = [Int](repeating: 0, count: 256)
        var chromatic = 0
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let p = row + x * 4
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                let luma = (r * 299 + g * 587 + b * 114) / 1000
                histogram[luma] += 1
                if max(r, g, b) - min(r, g, b) > 40 { chromatic += 1 }
            }
        }
        let total = width * height
        let threshold = BilevelScan.otsuThreshold(histogram)   // reuse, don't duplicate

        // Pass 2 — binary ink map + connected components (8-connectivity, two-pass union-find).
        var labels = [Int32](repeating: 0, count: total)
        var parent: [Int32] = [0]           // parent[0] unused; labels start at 1
        func find(_ l: Int32) -> Int32 {
            var l = l
            while parent[Int(l)] != l { parent[Int(l)] = parent[Int(parent[Int(l)])]; l = parent[Int(l)] }
            return l
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
        }
        var ink = 0
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let p = row + x * 4
                let luma = (Int(p[0]) * 299 + Int(p[1]) * 587 + Int(p[2]) * 114) / 1000
                guard luma < threshold else { continue }
                ink += 1
                let idx = y * width + x
                let left: Int32 = x > 0 ? labels[idx - 1] : 0
                let up: Int32 = y > 0 ? labels[idx - width] : 0
                let upLeft: Int32 = (x > 0 && y > 0) ? labels[idx - width - 1] : 0
                let upRight: Int32 = (x + 1 < width && y > 0) ? labels[idx - width + 1] : 0
                // Allocation-free equivalent of the brief's `[left, up, upLeft, upRight]
                // .filter { $0 > 0 }` then min-root + union-to-min: the array/filter allocated
                // once per ink pixel, which the hot double loop cannot afford. `root` is the
                // minimum positive neighbour label; every other positive neighbour unions into
                // it. Semantics (including the harmless double-union when two neighbours share a
                // label) are identical to the reference.
                var root: Int32 = 0
                if left > 0 { root = left }
                if up > 0, root == 0 || up < root { root = up }
                if upLeft > 0, root == 0 || upLeft < root { root = upLeft }
                if upRight > 0, root == 0 || upRight < root { root = upRight }
                if root > 0 {
                    labels[idx] = root
                    if left > 0, left != root { union(root, left) }
                    if up > 0, up != root { union(root, up) }
                    if upLeft > 0, upLeft != root { union(root, upLeft) }
                    if upRight > 0, upRight != root { union(root, upRight) }
                } else {
                    let label = Int32(parent.count)
                    parent.append(label)
                    labels[idx] = label
                }
            }
        }
        var areas: [Int32: Int] = [:]
        for idx in 0..<total where labels[idx] > 0 { areas[find(labels[idx]), default: 0] += 1 }
        // Specks below 3 px are scanner noise, not glyph components.
        let components = areas.values.filter { $0 >= 3 }
        let meanArea = components.isEmpty ? 0 : Double(components.reduce(0, +)) / Double(components.count)

        return MRCPageFeatures(inkCoverage: Double(ink) / Double(total),
                               meanComponentSize: meanArea,
                               componentCount: components.count,
                               colourCoverage: Double(chromatic) / Double(total))
    }

    /// Verdict on measured signals: `nil` = eligible, otherwise the decline reason.
    static func verdict(features f: MRCPageFeatures) -> MRCDeclineReason? {
        guard f.inkCoverage >= minInkCoverage, f.inkCoverage <= maxInkCoverage,
              f.colourCoverage <= maxColourCoverage,
              f.meanComponentSize > 0, f.meanComponentSize <= maxMeanComponentSize,
              f.componentCount >= minComponentCount
        else { return .notTextDominant }
        return nil
    }
}
