// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import PDFKit
import SwiftUI

/// Reusable components built on `Theme`, rebuilt from the Claude Design mockup
/// (kept outside this repository) — matching its feel, not its pixels.
/// Both this file and `QueueComponents.swift` are presentation-only: neither depends on
/// `ToolJob`/`CompressPreset`/view-model state. The real split is size: the app's small, generic
/// controls (buttons, thumbnails, section labels) live here; the larger, queue-specific rows and
/// cards (`QueueRow`, `VerbChip`, `OptionCard`, etc.) live in `QueueComponents.swift`. Consumed by
/// the unified queue's views (`QueueComponents.swift`, `Queue/*`) and the app chrome (`App/*`).

// MARK: - Hover tracking

/// The app's one hover-tracking mechanism — every view whose hover state drives on-screen chrome
/// (a fill, an opacity, a colour swap) uses this, never `.onHover` directly. EMPIRICAL basis (not
/// documented by Apple, traced live in this app): a synthetic/warped pointer — assistive input,
/// UI automation — moves via `mouseMoved` events but never crosses an AppKit tracking area, so
/// `.onHover`'s `mouseEntered`/`mouseExited` never fire for it and hover chrome stays dead.
/// `onContinuousHover`'s `.active`/`.ended` phases key off `mouseMoved` instead, so they still
/// fire. Same visual semantics as `.onHover`, strictly more robust input coverage.
extension View {
    func continuousHover(_ isHovering: Binding<Bool>) -> some View {
        onContinuousHover { phase in
            if case .active = phase { isHovering.wrappedValue = true } else { isHovering.wrappedValue = false }
        }
    }

    /// Closure variant, for the (rarer) site that needs to react to the transition rather than
    /// just store a `Bool` — e.g. only acting on hover-in, never on hover-out.
    func continuousHover(perform action: @escaping (Bool) -> Void) -> some View {
        onContinuousHover { phase in
            if case .active = phase { action(true) } else { action(false) }
        }
    }
}

// MARK: - MotionButtonStyle

/// The app's one press/hover motion, used in place of `.buttonStyle(.plain)` on every button in
/// the design system (DESIGN.md §8, DECISIONS 2026-08-01): press scales to `Theme.Motion.pressScale`
/// and, on the controls that ask for it, hover lifts 1pt and fades to `hoverOpacity`. Rendering is
/// otherwise `.plain`'s — the style draws no chrome of its own, so each component keeps its own
/// fill, ring and shadow.
///
/// **A component styled with this must draw its chrome INSIDE its `Button` label**, not on the
/// `Button` from outside: a `ButtonStyle` can only reach `configuration.label`, so background
/// applied outside would stay stubbornly still while the text alone shrank.
///
/// Hover/enabled state and the Reduce Motion gate live in a nested `View`, deliberately: a
/// `ButtonStyle` is not a `View`, so `@Environment` read directly in `makeBody` is not reliably
/// populated or updated — and the one thing that must never silently fail here is Reduce Motion.
struct MotionButtonStyle: ButtonStyle {
    /// Filled call-to-action behaviour — the handoff's `translateY(-1px)` hover rise. Off for
    /// every other control: rows, cards and secondary buttons hover by changing fill, not by
    /// moving.
    var lifts: Bool = false
    /// Opacity while hovered or pressed. `1` (no fade) for controls whose hover is a fill change;
    /// `Theme.Motion.hoverOpacity` for filled CTAs, `Theme.Motion.linkHoverOpacity` for links.
    var hoverOpacity: Double = 1

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, lifts: lifts, hoverOpacity: hoverOpacity)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let lifts: Bool
        let hoverOpacity: Double

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// A disabled control must not react to the pointer at all — its own component draws the
        /// disabled treatment.
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .scaleEffect(Theme.Motion.scale(isPressed: isPressed, reduceMotion: reduceMotion))
                .offset(y: lifts ? Theme.Motion.lift(isHovering: isHovering && isEnabled,
                                                     isPressed: isPressed,
                                                     reduceMotion: reduceMotion) : 0)
                .opacity(isEnabled && (isHovering || isPressed) ? hoverOpacity : 1)
                .animation(Theme.Motion.pressCurve(reduceMotion: reduceMotion), value: isPressed)
                .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
                .continuousHover($isHovering)
        }

        private var isPressed: Bool { configuration.isPressed && isEnabled }
    }
}

// MARK: - PrimaryButton

/// The primary call-to-action. Filled with `Theme.Colors.accent`, white label, disabled/hover
/// states.
///
/// Radius is DESIGN.md §5's `control` token (8px), not the `pill` token (980px): pill radius
/// is reserved for *link* CTAs ("Learn more"/"Shop") and compact badges, and the Claude
/// Design mockup draws both of its primary actions ("Choose Files…", "Compress N PDFs") as
/// small-radius buttons too. The design system's earlier pill reading of "CTA radius" was the
/// wrong half of §5.
struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 14/600: the handoff's "Choose Files…"/"Start" buttons — `.button`
            // (17/regular) predates the redesign and is a different, larger role.
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 22)
                // Solid `accent`, no shadow: DESIGN.md §7 forbids gradient backgrounds, §2's
                // `accent` token is a flat #0071e3 fill, and §6 puts buttons at Flat (Level 0) —
                // the one system shadow is the card's. The gradient (with its raw #0A84FF
                // literal) and the accent-tinted glow this replaces were an unrecorded
                // divergence: DECISIONS.md holds no entry for either. Drawn inside the label so
                // `MotionButtonStyle`'s press scale carries the pill, not just the text.
                .background(
                    Theme.Colors.accent,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                )
                // A plain-rendering style hit-tests only opaque content, so without an explicit
                // shape the padding is dead to clicks. Stays AFTER the padding.
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        // Hover: fade to `hoverOpacity` and rise 1pt; press: back to rest, scaled to .97
        // (handoff `style-hover="opacity:.9;transform:translateY(-1px)"`,
        // `style-active="transform:translateY(0) scale(.97)"`).
        .buttonStyle(MotionButtonStyle(lifts: true, hoverOpacity: Theme.Motion.hoverOpacity))
        .clearsClickFocus()
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        // Only offer the "clickable" cursor when the button can actually be pressed — a hand
        // over a disabled control promises something that will not happen.
        .modifier(HandCursorWhen(isEnabled: isEnabled))
    }
}

#Preview("PrimaryButton – Light") {
    PrimaryButton(title: "Compress 3 PDFs") {}
        .padding(40)
        .background(Theme.Colors.surface)
        .preferredColorScheme(.light)
}

#Preview("PrimaryButton – Dark") {
    VStack(spacing: 16) {
        PrimaryButton(title: "Compress 3 PDFs") {}
        PrimaryButton(title: "Disabled", isEnabled: false) {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - LinkButton

/// A borderless text action in DESIGN.md's link blue — the mockup's "+ Add", "Clear",
/// "Change…" affordances. Secondary to `PrimaryButton`: no fill, no border, just the link.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .themeFont(.link)
                .foregroundStyle(Theme.Colors.link)
                .contentShape(Rectangle())
        }
        // A link has no fill to hover, so it fades instead — the handoff's own treatment for
        // these spans (`transition:opacity .15s`, `style-hover="opacity:.6"`). No lift: they sit
        // in text runs, and a line of type that jumps on hover reads as a glitch.
        .buttonStyle(MotionButtonStyle(hoverOpacity: Theme.Motion.linkHoverOpacity))
        .clearsClickFocus()
        .pointingHandCursor()
    }
}

#Preview("LinkButton – Light") {
    HStack(spacing: 14) {
        LinkButton(title: "+ Add") {}
        LinkButton(title: "Clear finished") {}
        LinkButton(title: "Change…") {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.light)
}

#Preview("LinkButton – Dark") {
    HStack(spacing: 14) {
        LinkButton(title: "+ Add") {}
        LinkButton(title: "Clear finished") {}
        LinkButton(title: "Change…") {}
    }
    .padding(40)
    .background(Theme.Colors.surface)
    .preferredColorScheme(.dark)
}

// MARK: - SecondaryButton

/// A neutral filled button — "Show in Finder", "Enter password…", "Compare versions…". Dark
/// mode's `#3a3a3c` is a component-local pair, not a `Theme` token: it is NOT the same as
/// `Theme.Colors.surface`'s dark value (`#242426`) — the handoff genuinely uses a lighter grey
/// for these buttons than the window surface.
struct SecondaryButton: View {
    private static let background = Color(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x3A3A3C))

    let title: String
    var icon: Image? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon?.font(.system(size: 12, weight: .medium))
                Text(title).themeFont(.bodyStrong)
            }
            .foregroundStyle(Theme.Colors.text)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            // Fill, ring and shadow inside the label so the press scale carries all three (see
            // `MotionButtonStyle`); `contentShape` stays after the padding.
            .background(
                isHovering ? Theme.Colors.background : Self.background,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.Colors.stroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(MotionButtonStyle())
        .clearsClickFocus()
        .continuousHover($isHovering)
        .pointingHandCursor()
        // Handoff: `transition:background .15s`, hovering to `bg`. No lift — the handoff reserves
        // that for the filled accent CTAs.
        .animation(Theme.Motion.hoverCurve(reduceMotion: reduceMotion), value: isHovering)
    }
}

#Preview("SecondaryButton") {
    HStack(spacing: 10) {
        SecondaryButton(title: "Show in Finder", icon: Image(systemName: "folder"), action: {})
        SecondaryButton(title: "Change quality", action: {})
        SecondaryButton(title: "Cancel", action: {})
    }
    .padding(40)
    .background(Theme.Colors.surface)
}

// MARK: - PDFThumbnail

/// A preview of a PDF's first page with a small red PDF label beneath it.
///
/// A generic badge told the user nothing they did not already know from the filename; the page
/// itself is how anyone actually recognises a document. Rendering happens off the main actor —
/// `PDFDocument(url:)` reads and parses the whole file, which for a large scan is far too much
/// work to do while the row is being laid out.
struct PDFThumbnail: View {
    let url: URL?
    var width: CGFloat = 30
    /// Suppresses the red "PDF" label band, leaving a bare page render — `QueueComponents`'
    /// `VariantCard` (the scan-choice page-preview panel) wants the page itself with no
    /// file-type badge competing with it.
    var plain: Bool = false

    @State private var preview: NSImage?

    private var height: CGFloat { (width * 1.3).rounded() }         // roughly A4/Letter proportions
    /// A fifth of the card. Deep enough to hold the label comfortably, shallow enough that the
    /// thumbnail still reads as a page with a footer rather than a label with a picture above it.
    /// Zero in `plain` mode — there is no label band to reserve space for.
    private var bandHeight: CGFloat { plain ? 0 : (height * 0.21).rounded() }
    private let radius: CGFloat = 4.5

    var body: some View {
        VStack(spacing: 0) {
            page
            // Flush to the card's edges and centred by its own frame, so the label sits in the
            // base of the document rather than floating under it.
            if !plain {
                Text("PDF")
                    .font(.system(size: 6, weight: .heavy))
                    .kerning(0.35)
                    .foregroundStyle(.white)
                    .frame(width: width, height: bandHeight)
                    .background(Theme.Colors.documentBadge)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
        )
        // Two shadows, not one: a tight contact shadow anchors the card to the row, and a wider,
        // fainter one gives it depth. A single mid-radius shadow reads as a grey smudge at this
        // size and is most of why the first attempt looked cheap.
        .shadow(color: .black.opacity(0.28), radius: 0.8, x: 0, y: 0.5)
        .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 1.5)
        .task(id: url) { await loadPreview() }
    }

    /// The page itself, filling the card above the label band.
    private var page: some View {
        ZStack {
            Color.white
            if let preview {
                // Fill and crop rather than fit: a letterboxed thumbnail leaves grey bars inside
                // what is meant to read as a sheet of paper. The top of the page is the
                // recognisable part, so the crop is anchored there.
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height - bandHeight, alignment: .top)
            }
            // No spinner while loading: a row per file each flickering its own spinner makes a
            // whole batch look broken, and a blank sheet is the honest preview of a blank page.
        }
        .frame(width: width, height: height - bandHeight)
        .clipped()
    }

    private func loadPreview() async {
        preview = nil
        guard let url else { return }
        let pixels = CGSize(width: width * 3, height: height * 3)   // 3x, so it stays crisp on Retina
        let render = Task.detached(priority: .utility) { () -> NSImage? in
            // Checked twice, because `PDFDocument(url:)` reads and parses the whole file: a row
            // scrolled past before its turn comes up must not pay for the parse at all.
            guard !Task.isCancelled, let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            guard !Task.isCancelled else { return nil }
            return page.thumbnail(of: pixels, for: .mediaBox)
        }
        // A detached task does NOT inherit cancellation, so `.task(id:)`'s teardown has to be
        // forwarded by hand — without this the parse and render always run to completion and
        // only the result is thrown away.
        let rendered = await withTaskCancellationHandler {
            await render.value
        } onCancel: {
            render.cancel()
        }
        guard !Task.isCancelled else { return }
        preview = rendered
    }
}

// MARK: - SectionLabel

/// A small uppercase group label above a cluster of controls ("QUALITY", "ACCURACY"). The
/// positive `tracking` deliberately overrides `microBold`'s negative value: DESIGN.md tracks
/// tight for *reading* text, and uppercase micro-labels need the air back (the mockup sets
/// +0.4px on exactly these labels).
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .themeFont(.microBold)
            .tracking(0.4)
            .foregroundStyle(Theme.Colors.textTertiary)
    }
}

extension View {
    /// Keep a mouse click from leaving this control keyboard-focused — the recurring "stray blue
    /// square" defect. On modern macOS a click on any focusable SwiftUI control (plain-style
    /// buttons included) makes it first responder, and the system then draws a keyboard focus
    /// ring around it even though the user never touched the keyboard. Tab/arrow-key navigation
    /// is untouched: it assigns focus without a click, so its ring still shows, per DESIGN.md.
    ///
    /// House rule (see .claude/memory): EVERY `MotionButtonStyle` control gets this modifier
    /// unless it deliberately keeps click focus. Pair with `WindowSetup`'s key-window
    /// first-responder clear, which handles the rings AppKit assigns without any click.
    func clearsClickFocus() -> some View {
        modifier(ClearsClickFocusModifier())
    }

    /// Show the hand ("this is clickable") cursor while the pointer is inside.
    ///
    /// SwiftUI leaves the arrow in place for a tappable card, so a control built from a card
    /// rather than a `Button` gives the user no hover affordance at all.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

/// Backs `clearsClickFocus()`. The clear is deferred one runloop turn: the tap gesture can fire
/// before AppKit assigns first responder, and a synchronous clear would then be overwritten by
/// the very focus change it exists to prevent.
///
/// Known gap: `TapGesture` ends only on a press and release *inside* the control, while AppKit
/// takes first responder on mouse-DOWN — so pressing a control, dragging off it and releasing
/// leaves the ring behind. A zero-distance `DragGesture` would catch that, but this modifier is
/// attached to every `MotionButtonStyle` control in the app, and a drag recogniser on all of them
/// has far more blast radius (scrolling, the queue list) than the case it closes.
private struct ClearsClickFocusModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async { isFocused = false }
            })
    }
}

/// Backs `pointingHandCursor()`. Uses `NSCursor.set()` rather than `push()`/`pop()`: a pushed
/// cursor is only balanced by a matching `onHover(false)` on the *same* view instance, but a row
/// can leave mid-hover with no such event (removed from a list, its modifier swapped out when a
/// control becomes disabled, an `onOpen` going non-nil to nil) — leaking the hand cursor for the
/// rest of the session. `set()` has no stack to unbalance, and the `@State` flag plus
/// `onDisappear` make sure a torn-down view still restores the arrow.
///
/// Deliberately stays on `.onHover`, not `.continuousHover`: it drives the cursor, not on-screen
/// chrome, so it is outside this finding's "visible hover chrome" scope — converting it is a
/// separate concern (assistive-input cursor feedback) left unaddressed here.
private struct PointingHandCursorModifier: ViewModifier {
    @State private var isShowingHandCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                isShowingHandCursor = isInside
                (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .onDisappear {
                if isShowingHandCursor {
                    isShowingHandCursor = false
                    NSCursor.arrow.set()
                }
            }
    }
}

/// Applies the hand cursor only when a control is enabled.
private struct HandCursorWhen: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.pointingHandCursor() } else { content }
    }
}
