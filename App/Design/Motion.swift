import Foundation
import Observation
import SwiftUI

/// Low Power Mode, observed, so decorative motion can rest while it's on.
@MainActor
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PowerState.shared.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

extension EnvironmentValues {
    /// True while the window isn't in front or Low Power Mode is on. Decorative loops (blinks,
    /// shimmer, auras, pulsing dots) hold still; Reduce Motion stops them altogether.
    @Entry var pausesDecorativeMotion = false
}

/// Sets `pausesDecorativeMotion` for a window: the app in the background, Low Power Mode, and on
/// the Mac a window that isn't the key window (visible behind other apps, it kept animating all
/// day). Every window's root has it; the Settings and Inspector windows had none and never paused.
struct PausesMotionWhenAway: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.environment(\.pausesDecorativeMotion, pauses)
    }

    private var pauses: Bool {
        #if os(macOS)
        if !appearsActive { return true }
        #endif
        return scenePhase != .active || PowerState.shared.isLowPower
    }
}

extension View {
    func pausesMotionWhenAway() -> some View {
        modifier(PausesMotionWhenAway())
    }
}

/// A decorative loop (a pulsing halo, waving dots, a shimmer) that runs only while it can be seen:
/// shown, on screen, the window in front, no Reduce Motion. `content` gets `true` then, and its
/// moving part must exist only while it does: SwiftUI doesn't end a `repeatForever` animation
/// when its value is set back without one. A live dot in a row the sidebar's list had hidden for
/// reuse pulsed at the display's frame rate until the app quit, window in front or not (a Mac
/// core at 100% for 20 minutes). Taking the view away is what ends its animation. A hidden row
/// gets no `onDisappear`, so the sidebar also starts a new list when it swaps its rows.
struct DecorativeLoop<Content: View>: View {
    @ViewBuilder let content: (_ runs: Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @State private var isShown = false
    @State private var isOnScreen = true

    var body: some View {
        content(isShown && isOnScreen && !reduceMotion && !motionPaused)
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    }
}

#if DEBUG
/// How many shimmers sweep right now, for the UI tests' "one moving thing per place" checks
/// (`docs/chat.md` §4a). `-HERMES_MOTION_PROBE YES` shows it as a near-invisible element,
/// `motionProbe`, whose value is the count.
@MainActor
@Observable
final class MotionProbe {
    static let shared = MotionProbe()

    var sweeps = 0

    private init() {}

    static let isOn = UserDefaults.standard.bool(forKey: "HERMES_MOTION_PROBE")
}

private struct MotionProbeOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            if MotionProbe.isOn {
                Text(verbatim: "\(MotionProbe.shared.sweeps)")
                    .font(.system(size: 2))
                    .opacity(0.05)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("motionProbe")
                    .accessibilityLabel(Text(verbatim: "Motion probe"))
                    .accessibilityValue(Text(verbatim: "\(MotionProbe.shared.sweeps)"))
            }
        }
    }
}

extension View {
    /// `-HERMES_MOTION_PROBE YES`: the shimmer count on screen, for UI tests.
    func motionProbe() -> some View {
        modifier(MotionProbeOverlay())
    }
}
#endif

#if os(iOS)
/// Draws `content` in a SwiftUI host of its own, so an animation inside it redraws only it. While
/// any animation runs, SwiftUI updates the whole window it's in every frame: the live turn
/// header's words cross-fade each time a step starts, and in the chat's window each of those
/// frames cost about as much as a streamed word redrawing the reply (`docs/chat.md` §4a).
///
/// The host draws and nothing else: taps go to the view around it, and it takes from outside what
/// its content reads that the system doesn't hand a host (decorative motion pausing, and whether
/// it's scrolled out of sight). VoiceOver reads its content as part of the view around it. The
/// content is handed over only when it changed, so the view around it redrawing (a streamed
/// word) doesn't redraw the host.
///
/// iPhone and iPad only: on the Mac an AppKit host made a turn of many steps cost the main thread
/// more, not less, so there the words stay in the window's own host.
struct SeparateRedraws<Content: View & Equatable>: View {
    let content: Content
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibility
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOnScreen = true

    init(content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        OwnHost(hosted: Hosted(
            content: content,
            // A host has no scroll view around it to say it's out of sight: this one says.
            motionPaused: motionPaused || !isOnScreen,
            typeSize: typeSize, legibility: legibility, layoutDirection: layoutDirection, locale: locale, colorScheme: colorScheme
        ))
        .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    }

    /// The content with what it reads from outside.
    fileprivate struct Hosted: View, Equatable {
        let content: Content
        let motionPaused: Bool
        let typeSize: DynamicTypeSize
        let legibility: LegibilityWeight?
        let layoutDirection: LayoutDirection
        let locale: Locale
        let colorScheme: ColorScheme

        var body: some View {
            content
                .environment(\.pausesDecorativeMotion, motionPaused)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.legibilityWeight, legibility)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
        }
    }

    /// What the host draws, handed over as a change it observes rather than as a new root view:
    /// a host takes a new root without its animations, so the content's own fades didn't run.
    @Observable
    fileprivate final class Shown {
        var hosted: Hosted

        init(_ hosted: Hosted) {
            self.hosted = hosted
        }

        func show(_ new: Hosted) {
            if new != hosted { hosted = new }
        }
    }

    fileprivate struct Root: View {
        let shown: Shown

        var body: some View {
            shown.hosted
        }
    }

    private struct OwnHost: UIViewControllerRepresentable {
        let hosted: Hosted

        func makeUIViewController(context: Context) -> UIHostingController<Root> {
            let host = UIHostingController(rootView: Root(shown: Shown(hosted)))
            host.view.backgroundColor = .clear
            // Taps go to the view around it.
            host.view.isUserInteractionEnabled = false
            // Its content's size follows its own redraws (a fade holds both titles' room): the
            // view around it lays it out again when that changes, not on every frame of a fade.
            host.sizingOptions = .intrinsicContentSize
            host.safeAreaRegions = []
            return host
        }

        func updateUIViewController(_ host: UIHostingController<Root>, context: Context) {
            host.rootView.shown.show(hosted)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiViewController host: UIHostingController<Root>, context: Context) -> CGSize? {
            host.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
        }
    }
}
#endif
