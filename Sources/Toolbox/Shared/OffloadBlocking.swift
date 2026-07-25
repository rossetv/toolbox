// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Runs blocking work on a global queue and suspends until it finishes — the same
/// continuation-on-GCD shape `GhostscriptRunner.run` builds inline (§6.1). The engines call this
/// around synchronous file IO and page rendering (OCR's write+validate leg, CompressEngine's
/// validation gates) so a job suspends instead of parking a cooperative-pool thread, which would
/// starve every other queued job.
///
/// `.userInitiated`, deliberately: this wraps work a user is actively waiting on.
///
/// Caveat carried by every caller: `Task.checkCancellation()` INSIDE `work` is a silent no-op —
/// the closure runs on a GCD queue with no current task — so cancellation checks belong at the
/// call site, after the await returns.
func offloadBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
