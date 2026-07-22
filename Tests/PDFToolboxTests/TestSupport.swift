// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Shared test helpers.
///
/// Note on locating gs: tests construct `GhostscriptRunner()` so gs resolves via
/// `Bundle.main` to the copy **bundled inside the hosted test app** (under
/// `~/Library/Developer/Xcode/DerivedData/…`). They must NOT run the repo's
/// `Resources/ghostscript/bin/gs` directly: the repo lives under `~/Documents`, a
/// TCC-protected location, and a non-interactive xctest process launching a binary
/// there stalls indefinitely on a TCC decision (empirically verified). The bundled
/// path is both TCC-safe and the real production path (`Bundle.main`).
enum TestSupport {
    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }
}
