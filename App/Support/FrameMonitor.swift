#if DEBUG
import HermesKit
import QuartzCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Debug only (`-HERMES_FRAME_LOG YES`): logs every frame that took longer than its budget, so a
/// hitch during an animation (opening a chat, going back) shows as a line with its length. Times
/// count from the process's start, so a launch reads straight off the log. Each mark also closes a
/// span (`FRAMESPAN`, `FrameSpan`): the main thread's CPU, late frames and missed refreshes since
/// the mark before, what the performance run grades (docs/development.md, Performance check).
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var start: CFTimeInterval = 0
    private var lastCPU: Double = 0
    /// Main-thread CPU time since the last mark: unlike wall time, a busy machine doesn't inflate it.
    private var cpuSinceMark: Double = 0
    /// The span since the last mark, and that mark's name, time and main-thread CPU.
    private var span = FrameSpan()
    private var lastMark: (event: String, time: CFTimeInterval, cpu: Double, instructions: UInt64?)?
    /// Whether a sheet or an alert was over the window at some point in the span: a span read
    /// under one measured the sheet, not the chat. Looked at every few frames, and at each mark.
    private var sheetSeen = false
    private var framesSinceLook = 0

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    /// `proc_pid_rusage`, found at run time: the iOS SDK doesn't declare it, though the simulator's
    /// process has it as the Mac's does.
    private static let rusage: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32).self)
    }()

    /// Instructions the whole process has run: unlike CPU time, they don't change with how fast
    /// the cores are clocked, which other work on the machine sets (it can halve the CPU time the
    /// same frames take).
    private static func instructions() -> UInt64? {
        guard let rusage else { return nil }
        var info = rusage_info_v4()
        guard rusage(getpid(), RUSAGE_INFO_V4, &info) == 0, info.ri_instructions > 0 else { return nil }
        return info.ri_instructions
    }

    /// When the process started, on the display link's clock.
    private static func processStart() -> CFTimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return CACurrentMediaTime() }
        let started = info.kp_proc.p_starttime
        let wall = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return CACurrentMediaTime() - (Date.now.timeIntervalSince1970 - wall)
    }

    func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "HERMES_FRAME_LOG"), link == nil else { return }
        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #else
        // The Mac's display link follows the screen it's made from: the main one, where the
        // window opens in a measuring run.
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        start = Self.processStart()
        mark("launch: root view appears")
    }

    /// Marks an event in the log (a tap, a chat opening) so long frames can be read against it.
    func mark(_ event: String) {
        guard link != nil else { return }
        let now = CACurrentMediaTime()
        let cpu = Self.threadCPU()
        let instructions = Self.instructions()
        print(String(format: "FRAMELOG %8.1fms %@ (main cpu since last mark %.1fms, in all %.1fms)", (now - start) * 1000, event, cpuSinceMark, cpu))
        cpuSinceMark = 0
        if let lastMark {
            if Self.sheetShown { sheetSeen = true }
            var ran = ""
            if let before = lastMark.instructions, let instructions {
                ran = String(format: " instr_m=%.1f", Double(instructions &- before) / 1_000_000)
            }
            print(span.summary(wall: (now - lastMark.time) * 1000, cpu: cpu - lastMark.cpu).line(from: lastMark.event, to: event)
                + ran + Self.windowNote + (sheetSeen ? " sheet=shown" : ""))
            if ScrollProbe.isOn { print(ScrollProbe.shared.closeSpan()) }
        }
        span = FrameSpan()
        sheetSeen = Self.sheetShown
        lastMark = (event, now, cpu, instructions)
        // What a reply's end costs, and where the chat came to rest once it settled.
        if event == "reply ended" {
            Task {
                try? await Task.sleep(for: .seconds(2))
                mark("reply settled")
            }
        }
    }

    /// A covered Mac window gets no frames, so a span read while it was covered measured nothing.
    private static var windowNote: String {
        #if os(macOS)
        let covered = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !$0.occlusionState.contains(.visible) }
        return covered ? " window=covered" : ""
        #else
        return ""
        #endif
    }

    /// A sheet, an alert or a modal window over the app's windows.
    private static var sheetShown: Bool {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
        #else
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
        #endif
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let cpu = Self.threadCPU()
        defer { last = now; lastCPU = cpu }
        guard last > 0 else {
            mark("launch: first frame")
            return
        }
        let frame = now - last
        let work = cpu - lastCPU
        cpuSinceMark += work
        span.add(interval: frame * 1000, cpu: work, refresh: (link.targetTimestamp - link.timestamp) * 1000)
        if ScrollProbe.isOn { ScrollProbe.shared.sample() }
        // A few times a second: a sheet stays up far longer than that.
        framesSinceLook += 1
        if framesSinceLook >= 10 {
            framesSinceLook = 0
            if Self.sheetShown { sheetSeen = true }
        }
        if work > 8 {
            print(String(format: "FRAMELOG %8.1fms busy frame: main cpu %.1fms (wall %.1fms)", (now - start) * 1000, work, frame * 1000))
        }
    }
}
#endif
