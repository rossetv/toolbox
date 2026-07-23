// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import SwiftUI

@main
struct PDFToolboxApp: App {
    init() {
        // Headless self-test hook (PDFTOOLBOX_SMOKE=compress) — runs the real compress path
        // from the app process and exits, before any window appears.
        CompressSmoke.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
    }
}
