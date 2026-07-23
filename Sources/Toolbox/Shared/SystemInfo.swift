// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

enum SystemInfo {
    /// Apple-Silicon performance-core count (`hw.perflevel0.logicalcpu`) — the default batch
    /// concurrency cap so background compression/OCR doesn't saturate the efficiency cores or
    /// contend for P-cores. Falls back to the active processor count on non-Apple-Silicon.
    static var performanceCoreCount: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}
