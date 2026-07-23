// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit

/// Enforces the window's minimum size on the `NSWindow` itself.
///
/// SwiftUI's `.frame(minWidth:minHeight:)` constrains the CONTENT, not the window: a window that
/// opens (or is restored from a previous session) smaller than that simply clips. In a
/// `NavigationSplitView` the casualty is the sidebar — it collapses to zero width and the detail
/// pane is pushed up under the titlebar. That is exactly how this app shipped: an apparently
/// empty sidebar on a window a few hundred points too small. Setting `NSWindow.minSize` makes the
/// constraint real, and growing an already-too-small frame repairs a bad restored size on launch.
///
/// Deliberately a plain function rather than an `NSViewRepresentable` placed in `.background`:
/// a representable participates in SwiftUI's layout and displaced the sidebar list upwards by a
/// titlebar's height. Reaching for the window directly has no layout effect at all.
enum WindowSetup {

    static func applyMinimumSize(_ minSize: NSSize) {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.contentView != nil && window.canBecomeMain {
                window.minSize = minSize
                // The sidebar list does not inset itself for the titlebar, so with a
                // full-size content view its rows draw a titlebar's height too high — over the
                // traffic lights, with the first entries scrolled out of sight entirely.
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false

                var frame = window.frame
                guard frame.width < minSize.width || frame.height < minSize.height else { continue }
                let grown = NSSize(width: max(frame.width, minSize.width),
                                   height: max(frame.height, minSize.height))
                // AppKit origins are bottom-left: drop the origin by the height gained so the
                // window grows downwards and its titlebar stays put.
                frame.origin.y -= grown.height - frame.height
                frame.size = grown
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}
