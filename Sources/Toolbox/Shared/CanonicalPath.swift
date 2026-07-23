// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

extension URL {
    /// The fully canonical filesystem path — resolves symlinks in the path prefix,
    /// **crucially `/var` → `/private/var` and `/tmp` → `/private/tmp`**, which
    /// `resolvingSymlinksInPath()` does *not* do (verified). This matters for seatbelt
    /// scoping: the kernel resolves gs's file accesses to their real `/private/var` paths,
    /// so a profile scope entry left as `/var/…` silently fails to match and the access is
    /// denied. For a not-yet-existing leaf (e.g. an output temp file), canonicalises the
    /// existing parent directory and re-appends the leaf.
    var canonicalPath: String {
        if let real = URL.realpath(path) { return real }
        let parent = deletingLastPathComponent()
        if parent.path != path, let realParent = URL.realpath(parent.path) {
            return (realParent as NSString).appendingPathComponent(lastPathComponent)
        }
        return path
    }

    /// The canonical URL (see `canonicalPath`).
    var canonical: URL { URL(fileURLWithPath: canonicalPath) }

    private static func realpath(_ path: String) -> String? {
        path.withCString { cString -> String? in
            guard let resolved = Darwin.realpath(cString, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
