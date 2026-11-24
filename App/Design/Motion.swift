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
        if PerfAblate.motion { return true }
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

/// Measurement-only switches for the Mac streaming check (`docs/development.md` Performance check):
/// `-HERMES_PERF_ABLATE motion,timers,chat,sidebar,composer` turns off one suspect at a time so cost
/// can be attributed by "does it still stutter without it". Debug builds read the flag once at
/// launch; Release folds every switch to `false`, so none of this ships.
enum PerfAblate {
    #if DEBUG
    private static let flags: Set<String> = {
        let raw = UserDefaults.standard.string(forKey: "HERMES_PERF_ABLATE") ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()
    /// Hold every decorative loop still (shimmer, halos, the face's own motion).
    static var motion: Bool { flags.contains("motion") }
    /// Stop the periodic time ticks (live header, running step, process step, process chip).
    static var timers: Bool { flags.contains("timers") }
    /// Drop the step rows' fade-in transitions (steps arrive faster than the fade lasts).
    static var transitions: Bool { flags.contains("transitions") }
    /// Drop the header title's cross-fade (the words change faster than the fade lasts).
    static var titles: Bool { flags.contains("titles") }
    /// Blank the transcript, the sidebar rows, or the composer, one at a time.
    static var chat: Bool { flags.contains("chat") }
    static var sidebar: Bool { flags.contains("sidebar") }
    static var composer: Bool { flags.contains("composer") }
    #else
    static var motion: Bool { false }
    static var timers: Bool { false }
    static var transitions: Bool { false }
    static var titles: Bool { false }
    static var chat: Bool { false }
    static var sidebar: Bool { false }
    static var composer: Bool { false }
    #endif
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
