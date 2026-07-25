// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import PDFKit

/// The up-front openability of an input PDF (spec R2-N3, shared by both tools).
enum OpenState: Equatable {
    case ok(pageCount: Int)
    case encrypted
    case corrupt
}

enum OpenGuardError: Error, LocalizedError {
    case fileNotFound
    case noPages

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "The file could not be found."
        case .noPages: return "The PDF contains no pages."
        }
    }
}

/// Detects encrypted or corrupt PDFs before either engine touches them. Both engines call
/// `inspect` first: an encrypted (locked) file is prompted-or-skipped, a corrupt file fails
/// inline (the batch continues with the rest).
enum OpenGuard {
    static func inspect(_ url: URL) throws -> OpenState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenGuardError.fileNotFound
        }
        guard let doc = PDFDocument(url: url) else {
            return .corrupt
        }
        // A user-password-protected PDF opens locked; owner-only (no user password) opens
        // usable, so gate on `isLocked`, not merely `isEncrypted`.
        if doc.isEncrypted && doc.isLocked {
            return .encrypted
        }
        // A pageless document is nothing either engine can work on, and passing it through as
        // `.ok(pageCount: 0)` would surface far downstream as "the compressed PDF failed
        // validation" — a lie about which file is at fault. Measured on this machine, PDFKit
        // refuses every pageless page tree we could author (so `.corrupt` normally fires first);
        // this says the honest thing should a future PDFKit admit one.
        guard doc.pageCount > 0 else { throw OpenGuardError.noPages }
        return .ok(pageCount: doc.pageCount)
    }
}
