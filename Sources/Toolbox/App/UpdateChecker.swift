// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Notify-only update check (the app's ONLY network request — a deliberate, documented
/// exception to the no-network posture; see README "Good to know").
///
/// On launch, fetches the latest GitHub release tag and compares it against the running
/// version. If newer, the UI shows an update banner whose button opens the release page —
/// the app never downloads or replaces its own binary: an unsigned self-replace would turn
/// a compromised release channel into silent code execution on every user's machine.
///
/// Any failure — offline, rate-limited, malformed response — resolves to "no update";
/// a version check must never degrade the tools that work entirely offline.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String   // normalised, no leading "v"
        let pageURL: URL
    }

    @Published private(set) var available: Release?

    /// Injected so tests can stub the network; the default performs the real request.
    private let fetchLatest: () async throws -> Data

    init(fetchLatest: (() async throws -> Data)? = nil) {
        self.fetchLatest = fetchLatest ?? {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/rossetv/toolbox/releases/latest")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    func check(currentVersion: String? = nil) async {
        let current = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0"
        guard let data = try? await fetchLatest(),
              let release = Self.parseRelease(data),
              Self.isNewer(release.version, than: current) else { return }
        available = release
    }

    /// Extract the tag and page URL from a GitHub `releases/latest` payload.
    /// Returns `nil` for anything malformed — never a guess.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.html_url),
              url.scheme == "https",
              // Pin to the release host we actually queried — a compromised or
              // malicious API response must not one-click the user to an arbitrary host.
              url.host == "github.com" else { return nil }
        let version = payload.tag_name.hasPrefix("v")
            ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard !version.isEmpty,
              // Bound length and component count so a hostile tag (e.g. "1" + ".0" x 100_000)
              // can't blow up parsing/comparison or overflow the UI banner.
              version.count <= 32,
              version.split(separator: ".", omittingEmptySubsequences: false).count <= 8
        else { return nil }
        return Release(version: version, pageURL: url)
    }

    /// Numeric dot-component comparison: "0.2.0" > "0.1.0", "0.10.0" > "0.9.1",
    /// missing components read as 0 ("1.0" == "1.0.0"). A remote version that fails to
    /// parse at all compares NOT newer — a junk tag must not raise the banner.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func components(_ s: String) -> [Int]? {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let r = components(remote) else { return false }
        // An unparseable LOCAL version fails open (any valid remote counts as newer):
        // the banner is the recoverable outcome; hiding updates forever is not.
        guard let l = components(local) else { return true }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
