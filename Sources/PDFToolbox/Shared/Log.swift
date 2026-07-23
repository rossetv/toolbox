// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import os

/// Unified-logging categories. Never log file contents or full paths of user documents;
/// log outcomes and errors.
enum Log {
    private static let subsystem = "com.pdftoolbox.app"
    static let compress = Logger(subsystem: subsystem, category: "compress")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let general = Logger(subsystem: subsystem, category: "general")
}
