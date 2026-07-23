// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import UniformTypeIdentifiers

/// File selection via `NSOpenPanel`.
///
/// SwiftUI's `.fileImporter` is used instead of this in many samples, but two `.fileImporter`
/// modifiers attached to the same view (here: one for input PDFs, one for the output folder)
/// conflict on macOS and neither reliably presents — which is exactly how this app shipped with a
/// "Choose Files…" button that did nothing at all. `NSOpenPanel` is the platform's own API, has no
/// such limitation, and returns its result synchronously, so the call sites stay simple.
@MainActor
enum FilePicker {

    /// Pick one or more PDFs. Returns an empty array if the user cancels.
    static func choosePDFs() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose PDFs"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Pick a destination folder. Returns nil if the user cancels.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an output folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
