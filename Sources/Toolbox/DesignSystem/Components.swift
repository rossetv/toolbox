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
        continuousHover { isHovering.wrappedValue = $0 }
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

// MARK: - ParallaxAppIcon

/// The real app icon leaning towards the pointer, over an accent glow that slides the opposite way
/// and under a specular sheen that follows it — the handoff's three `[data-parallax-*]` layers
/// (DESIGN.md §8: ~90ms follow, ±11°/±13° rotation, ±7px translate, 1.05 scale, glow in
/// counter-phase). Screens 01 and About both draw it, at different sizes, which is why it lives
/// here rather than inside either of them.
///
/// The sheen is MASKED to the icon's own artwork. Unmasked it slides off the icon at full tilt and
/// renders as a stray pale rounded square beside it, which is what the empty state was showing.
/// Glow and sheen are attached outside the tilt so they stay flat, as the handoff's
/// siblings-in-a-perspective-box markup has them, and via `background`/`overlay` so the glow can
/// overflow without widening the layout slot.
///
/// `pointer` is the ±1 offset from the centre of whatever stage the caller tracks (see
/// `parallaxStage(_:)`), `nil` at rest — every layer is a pure function of it, so "at rest" is one
/// state rather than three. Reduce Motion simply leaves it `nil`.
struct ParallaxAppIcon: View {
    var size: CGFloat = 76
    var pointer: CGPoint?

    /// Every offset below is expressed against the 76pt empty-state icon the handoff specifies, so
    /// a bigger instance (the About sheet's 84pt) scales its glow and sheen with it rather than
    /// wearing the smaller icon's travel.
    private var scale: CGFloat { size / 76 }

    private var artwork: Image {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
    }

    var body: some View {
        let p = pointer ?? .zero
        return artwork
            .frame(width: size, height: size)
            .overlay { sheen(p).mask(artwork) }
            .scaleEffect(pointer == nil ? 1 : 1.05)
            .modifier(PointerTilt(dx: p.x, dy: p.y))
            .background { glow(p) }
            // Decorative in both homes: the headline beneath it in the empty state, and the app
            // name beneath it in About, already say what it is.
            .accessibilityHidden(true)
    }

    private func glow(_ p: CGPoint) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [Theme.Colors.accent.opacity(0.26), Theme.Colors.accent.opacity(0)],
                center: .center,
                // 66% of the CSS gradient's farthest-corner radius (52√2) on a 104px box.
                startRadius: 0, endRadius: 48.54 * scale
            ))
            .frame(width: 104 * scale, height: 104 * scale)
            .scaleEffect(1 + abs(p.x) * 0.12)
            // Resting centre sits at 58% of the icon box — 6.08px below its middle at 76pt.
            .offset(x: -p.x * 16 * scale, y: 6.08 * scale - p.y * 12 * scale)
    }

    private func sheen(_ p: CGPoint) -> some View {
        Rectangle()
            .fill(LinearGradient(
                stops: [.init(color: .white.opacity(0.6), location: 0),
                        .init(color: .white.opacity(0), location: 0.48)],
                // The handoff's 125° gradient line across the icon's square.
                startPoint: UnitPoint(x: -0.071, y: 0.100),
                endPoint: UnitPoint(x: 1.071, y: 0.900)
            ))
            .opacity(pointer == nil ? 0 : 0.16 + min(1, abs(p.x) + abs(p.y)) * 0.42)
            .offset(x: p.x * 22 * scale, y: p.y * 16 * scale)
            // Scaled past the icon so a full-tilt offset still covers it — the mask, not the
            // rectangle's own edges, is what shapes this layer.
            .scaleEffect(2)
    }

    /// Pointer offset from the stage centre, ±1 at the edges — the handoff's own normalisation,
    /// clamped because `onContinuousHover` can report a location just outside the bounds.
    static func normalise(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(1, max(-1, (location.x - size.width / 2) / (size.width / 2))),
                       y: min(1, max(-1, (location.y - size.height / 2) / (size.height / 2))))
    }
}

/// The handoff's `[data-parallax-icon]` transform, reproduced exactly: `rotateX(-dy·11°)
/// rotateY(dx·13°) translate3d(dx·7px, dy·7px, 0)` inside a **700px-perspective** container.
///
/// Spec §7 names `rotation3DEffect`; this composes the same rotation directly because
/// `rotation3DEffect`'s `perspective` argument has no documented unit — there is no value that
/// provably corresponds to the handoff's `perspective:700px`, and chaining two of them applies
/// two separate projections, which is what read as a shear. `m34 = -1/700` is the same number
/// the CSS states, and it is the near/far foreshortening that makes the tilt read as depth.
private struct PointerTilt: GeometryEffect {
    var dx: Double
    var dy: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(dx, dy) }
        set { (dx, dy) = (newValue.first, newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Each `CATransform3D*` call prepends, so the applied order is translate → rotateY →
        // rotateX → perspective: the CSS transform list read right to left.
        var t = CATransform3DIdentity
        t.m34 = -1 / 700
        t = CATransform3DRotate(t, -dy * 11 * .pi / 180, 1, 0, 0)
        t = CATransform3DRotate(t, dx * 13 * .pi / 180, 0, 1, 0)
        t = CATransform3DTranslate(t, dx * 7, dy * 7, 0)
        // CSS `transform-origin: 50% 50%`: rotate about the icon's middle, not its top-left.
        let toCentre = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(toCentre)
            .concatenating(ProjectionTransform(t))
            .concatenating(ProjectionTransform(toCentre.inverted()))
    }
}

/// Backs `parallaxStage(_:)`. Owns the stage measurement so neither caller needs a `GeometryReader`
/// wrapped round its own layout just to know how big it is.
private struct ParallaxStageModifier: ViewModifier {
    @Binding var pointer: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stageSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { stageSize = geo.size }
                        .onChange(of: geo.size) { _, newValue in stageSize = newValue }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !reduceMotion else { return }
                    // ~90ms follow (DESIGN.md §8) — near-immediate, not the exit-only settle spring.
                    withAnimation(.easeOut(duration: 0.09)) {
                        pointer = ParallaxAppIcon.normalise(location, in: stageSize)
                    }
                case .ended:
                    // Deliberately not gated on Reduce Motion: turning it on mid-hover must still
                    // let the icon come to rest rather than freeze mid-tilt.
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { pointer = nil }
                }
            }
    }
}

#Preview("ParallaxAppIcon") {
    HStack(spacing: 40) {
        ParallaxAppIcon(size: 76, pointer: nil)
        ParallaxAppIcon(size: 76, pointer: CGPoint(x: 1, y: -1))
        ParallaxAppIcon(size: 84, pointer: CGPoint(x: -0.5, y: 0.5))
    }
    .padding(50)
    .background(Theme.Colors.surface)
}

/// The one owner of "Escape closes the frontmost dismissable thing" (`CODE_GUIDELINES.md` §8.2).
///
/// A single app-wide key-down monitor over a STACK of dismiss actions. Escape calls the frontmost
/// registered dismisser and nobody else: entries carry an explicit `Depth` (a sheet is 0, a
/// popover 1), the deepest wins, and registration order breaks ties. An earlier attempt scoped a
/// per-view monitor by comparing `event.window` against the view's host window; whether an
/// `NSPopover`'s window is the one a key-down is posted to is not something this repo can settle
/// (this project's own memory records that a popover never takes key status), and a fix resting on
/// an unsettled runtime fact is a guess.
///
/// Depth rather than registration order ALONE, which was the first shape of this: order only
/// matches nesting while every presentation opens inside the one below it, and this app can break
/// that — a consent sheet arrives mid-run (`QueueView`'s `pendingConsents` observer) while a
/// versions popover is open, registering *after* the popover it sits behind. Apple documents
/// `onAppear`/`onDisappear` timing as "depends on the specific view type", so leaning on order for
/// correctness would have been the same class of guess as the window check.
///
/// Known gap, accepted: `pop` runs only from `onDisappear`. A registration orphaned by a teardown
/// that never delivers one would leave the monitor installed and swallowing every Escape in the
/// app. Nothing observed — reported here rather than papered over with a window-liveness check,
/// which is the plumbing this design exists to avoid.
///
/// A monitor rather than `.keyboardShortcut(.cancelAction)` on a close button: the in-window
/// sheets are not real presentations, and every control in them clears its own click focus
/// (DESIGN.md §6's stray-ring rule), so the window frequently has no first responder for SwiftUI
/// to route a shortcut through. A monitor sees the key regardless of who holds focus, and
/// consuming the event stops it reaching anything behind.
///
/// NOT verified in the UI-automation environment this was written in: a key-code probe showed
/// ordinary keys reaching a monitor of this kind while keyCode 53 never arrived from EITHER a
/// CGEvent-based driver or `System Events`, so something upstream of the app swallows Escape
/// there. The mechanism is ordinary AppKit; it wants a check by hand.
/// How far in front a dismissable presentation sits. Two real values, no more: everything this app
/// presents is one or the other.
enum EscapeDepth {
    case sheet
    case popover
}

@MainActor
private enum EscapeResponders {
    private struct Entry {
        let id: UUID
        let depth: EscapeDepth
        let action: () -> Void
    }

    private static var stack: [Entry] = []
    private static var monitor: Any?

    static func push(_ id: UUID, depth: EscapeDepth, action: @escaping () -> Void) {
        stack.append(Entry(id: id, depth: depth, action: action))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Escape
            guard let top = frontmost else { return event }
            top.action()
            return nil                                        // handled: stop dispatch
        }
    }

    /// The last-registered popover if any is open, else the last-registered anything. `stack` is
    /// append-ordered, so "last" IS registration order — no sequence number needed. Deliberately
    /// not `MainActor.assumeIsolated`: AppKit documents no queue for a monitor handler, so the
    /// assertion would trade an undocumented-but-observed invariant for a hard crash, and it
    /// demands `NSEvent: Sendable`, which is an error in the Swift 6 language mode.
    private static var frontmost: Entry? {
        stack.last { $0.depth == .popover } ?? stack.last
    }

    static func pop(_ id: UUID) {
        stack.removeAll { $0.id == id }
        guard stack.isEmpty, let installed = monitor else { return }
        NSEvent.removeMonitor(installed)
        monitor = nil
    }
}

private struct EscapeToDismiss: ViewModifier {
    let depth: EscapeDepth
    let action: () -> Void

    /// Identity for this registration, stable across body passes.
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { EscapeResponders.push(id, depth: depth, action: action) }
            .onDisappear { EscapeResponders.pop(id) }
    }
}

extension View {
    /// Close this on Escape, the way a system sheet does for free. `depth` says how far in front
    /// this presentation sits, so a popover opened from a sheet answers before the sheet whatever
    /// order the two happened to register in.
    func escapeToDismiss(depth: EscapeDepth, _ action: @escaping () -> Void) -> some View {
        modifier(EscapeToDismiss(depth: depth, action: action))
    }

    /// Track the pointer across this view and publish it as the ±1 offset from the view's centre
    /// that `ParallaxAppIcon` leans on — `nil` while the pointer is away. The stage is the whole
    /// area the icon reacts to, which is deliberately larger than the icon itself.
    func parallaxStage(_ pointer: Binding<CGPoint?>) -> some View {
        modifier(ParallaxStageModifier(pointer: pointer))
    }

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
/// Uses `.continuousHover`, whose `.active` phase fires per mouse-move, so the cursor is RE-SET on
/// every motion inside the control. That repetition is the point, not waste. EMPIRICAL (traced live
/// with a cursor-inclusive `screencapture -C`): a single `set()` on hover-in survives only until
/// AppKit next re-evaluates its cursor rects, and any change to the view tree does that — hovering
/// a queue row's name inserts the row's gear and × buttons, which put the arrow straight back while
/// the pointer had not moved off the name. The gear read as "working" only because hovering it
/// changes nothing. Re-asserting per move also fixes the synthetic/warped pointer that never
/// crosses an AppKit tracking area at all (see `continuousHover`'s own note).
private struct PointingHandCursorModifier: ViewModifier {
    @State private var isShowingHandCursor = false

    func body(content: Content) -> some View {
        content
            .continuousHover { isInside in
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
