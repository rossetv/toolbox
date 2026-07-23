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
///  2. `features(of:)`/`verdict(for:)` (Task 6) — signal measurement on one low-DPI render.
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
}
