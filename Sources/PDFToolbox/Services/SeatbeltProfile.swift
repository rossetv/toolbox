// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Builds the macOS seatbelt (`sandbox-exec`) profile that contains every Ghostscript
/// invocation. Input PDFs are untrusted and gs has a CVE history (spec §5.4), so gs runs
/// with **no network** and the filesystem **restricted to exactly** the input file, the
/// output directory, gs's own binary directory, and a per-run scratch dir.
///
/// The pattern below is empirically verified (not string-inspected): under it gs launches
/// and compresses, while a read or write outside the scope is denied and the network is
/// closed. Two elements are essential and load-bearing:
///
///  - `(deny default)` — SBPL defaults to *allow*; without a default-deny the file/network
///    scoping would confine nothing. The `system.sb`/`bsd.sb` imports then re-grant only the
///    system essentials gs needs to launch (dyld, `/usr/lib` + `/System` reads, mach lookups,
///    syscalls, sysctl).
///  - `(allow process-exec* (literal <gsPath>))` — `sandbox-exec` refuses to exec gs without
///    it (`execvp Operation not permitted`).
///
/// All paths are canonicalised (`resolvingSymlinksInPath`) so a `/var` vs `/private/var`
/// mismatch between a scope entry and gs's actual access can never silently deny.
enum SeatbeltProfile {
    /// - Parameters:
    ///   - gsPath: the gs binary. Its containing directory is always added to the read scope.
    ///   - readPaths: files/dirs gs may read (the input PDF, the scratch dir).
    ///   - writePaths: files/dirs gs may write (the output dir, the scratch dir).
    static func profile(gsPath: URL, readPaths: [URL], writePaths: [URL]) -> String {
        let gs = gsPath.canonical
        let gsDir = gs.deletingLastPathComponent()

        // gs's own directory is always readable; de-duplicate the rest.
        let reads = dedupe([gsDir] + readPaths.map { $0.canonical })
        let writes = dedupe(writePaths.map { $0.canonical })

        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "(import \"bsd.sb\")",
            "(allow process-exec* (literal \(quote(gs.path))))",
            "(deny network*)",
        ]
        lines.append("(allow file-read* " + reads.map(scopeEntry).joined(separator: " ") + ")")
        if !writes.isEmpty {
            lines.append("(allow file-write* " + writes.map(scopeEntry).joined(separator: " ") + ")")
        }
        return lines.joined(separator: "\n")
    }

    /// A directory becomes `(subpath …)`; a file (or a not-yet-created path) becomes `(literal …)`.
    private static func scopeEntry(for url: URL) -> String {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            return "(subpath \(quote(url.path)))"
        }
        return "(literal \(quote(url.path)))"
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// SBPL string literal with backslashes and quotes escaped.
    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
