// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Builds the macOS seatbelt (`sandbox-exec`) profile that contains every Ghostscript
/// invocation. Input PDFs are untrusted and gs has a CVE history (spec §5.4), so gs runs
/// with **no network** and **USER DATA** confined to exactly the input file, the output
/// directory, gs's own binary directory, and a per-run scratch dir.
///
/// That confinement is over the app's *own* data, not the whole filesystem: `system.sb`/
/// `bsd.sb` (imported below, needed for gs to launch at all) re-grant the usual world-readable
/// system paths, so e.g. `/etc/passwd` and `/usr/share/dict/words` remain readable under this
/// profile — same as under any other sandboxed process using those imports. That is not a hole
/// in this scoping: none of it is user data, and gs never receives credentials to exfiltrate.
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
    ///   - readPaths: files/dirs gs may read (the input PDF, the scratch dir). A directory MUST
    ///     be constructed with `isDirectory: true` (or a trailing slash) — that is how its
    ///     scope entry is decided; see `ScopedPath` below.
    ///   - writePaths: files/dirs gs may write (the output dir, the scratch dir). Same rule.
    static func profile(gsPath: URL, readPaths: [URL], writePaths: [URL]) -> String {
        let gs = gsPath.canonical
        let gsDir = ScopedPath(canonical: gs.deletingLastPathComponent(), isDirectory: true)

        // gs's own directory is always readable; de-duplicate the rest.
        let reads = dedupe([gsDir] + readPaths.map(ScopedPath.init))
        let writes = dedupe(writePaths.map(ScopedPath.init))

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

    /// A canonicalised path paired with whether the CALLER intended it as a directory.
    ///
    /// The intent is captured from the original URL — via `hasDirectoryPath`, itself driven by
    /// how the URL was constructed (`isDirectory: true` or a trailing slash), never a filesystem
    /// stat — and captured *before* canonicalising: `.canonical` reconstructs the URL via
    /// `URL(fileURLWithPath:)`, which re-derives directory-ness from whatever is on disk at that
    /// moment, and would silently default a not-yet-created directory to "not a directory". That
    /// silent loss is exactly what let a not-yet-created write directory decay into a `(literal
    /// …)` file entry, denying every write inside it. Capturing the flag here, from the caller's
    /// own URL, makes that call explicit rather than inferred.
    private struct ScopedPath {
        let canonical: URL
        let isDirectory: Bool

        init(_ url: URL) {
            self.isDirectory = url.hasDirectoryPath
            self.canonical = url.canonical
        }

        init(canonical: URL, isDirectory: Bool) {
            self.canonical = canonical
            self.isDirectory = isDirectory
        }
    }

    /// A directory becomes `(subpath …)`; a file becomes `(literal …)`. The filesystem is the
    /// primary signal (authoritative once the path exists — which it does for every real caller,
    /// since each creates its directory before profiling it), with the caller's own stated intent
    /// (`ScopedPath.isDirectory`) as a fallback for a path that doesn't exist YET at profile-build
    /// time: a live `fileExists` obviously cannot see a directory that isn't there yet.
    private static func scopeEntry(for path: ScopedPath) -> String {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.canonical.path, isDirectory: &isDir)
        let isDirectory = (exists && isDir.boolValue) || path.isDirectory
        return isDirectory
            ? "(subpath \(quote(path.canonical.path)))"
            : "(literal \(quote(path.canonical.path)))"
    }

    private static func dedupe(_ paths: [ScopedPath]) -> [ScopedPath] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0.canonical.path).inserted }
    }

    /// SBPL string literal with backslashes and quotes escaped.
    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
