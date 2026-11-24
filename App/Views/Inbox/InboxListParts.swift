import HermesKit
import SwiftUI

// MARK: - Filters

/// The inbox's filter menu (`docs/inbox.md` §5): the sources it holds, the states that narrow
/// Main, Hide Empty Chats, then Mark All as Read and Show Everything. The sidebar's filter button,
/// iPhone's bottom bar and the Mac's View ▸ Filter menu all show it. Kept per gateway.
struct InboxFilterMenuContent: View {
    @Bindable var workspace: BotWorkspace

    var body: some View {
        let counts = workspace.stateCounts()
        Section("Sources") {
            ForEach(InboxSourceGroup.allCases, id: \.self) { group in
                Toggle(isOn: source(group)) {
                    Label(group.title, systemImage: group.symbol)
                }
            }
        }
        Section("Only") {
            Toggle(isOn: $workspace.inboxScope.unreadOnly) {
                Text("Unread")
                if counts.unread > 0 { Text("\(counts.unread)") }
            }
            Toggle(isOn: $workspace.inboxScope.needsYouOnly) {
                Text("Needs You")
                if counts.needsYou > 0 { Text("\(counts.needsYou)") }
            }
        }
        Section {
            Toggle("Hide Empty Chats", isOn: $workspace.inboxScope.hidesEmpty)
        }
        Section {
            Button("Mark All as Read", systemImage: "envelope.open") {
                Task { await workspace.unread.markAllRead(workspace.unreadChatKeys) }
            }
            .disabled(counts.unread == 0)
            if !workspace.inboxScope.isStandard {
                Button("Show Everything", systemImage: "line.3.horizontal.decrease.circle") {
                    workspace.inboxScope = .standard
                }
            }
        }
    }

    private func source(_ group: InboxSourceGroup) -> Binding<Bool> {
        Binding {
            workspace.inboxScope.shows(group)
        } set: { shown in
            workspace.inboxScope.set(group, shown: shown)
        }
    }
}

/// The filter button: filled for any choice but the standard one (every source but scheduled
/// runs, empty chats hidden, nothing narrowed), so a narrowed list is never a surprise, and saying
/// what it changes in VoiceOver.
struct InboxFilterButton: View {
    @Bindable var workspace: BotWorkspace

    var body: some View {
        let scope = workspace.inboxScope
        Menu {
            InboxFilterMenuContent(workspace: workspace)
        } label: {
            Label("Filter", systemImage: scope.isStandard
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(scope.isStandard ? String(localized: "Everything") : scope.summary)
        .accessibilityIdentifier("inbox.filter")
    }
}

/// "Filtered: No Telegram · Unread ✕" at the top of a filtered inbox: what it leaves out, and a
/// tap back to everything (`docs/inbox.md` §5).
struct FilteredLine: View {
    @Bindable var workspace: BotWorkspace

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text("Filtered: \(workspace.inboxScope.summary)")
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                withAnimation(Theme.snappy) { workspace.inboxScope = .standard }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Everything")
        }
        .font(.footnote)
        .padding(.vertical, 6)
        .modifier(SidebarRowInsets())
    }
}

/// A filter with nothing in it (`caughtUp`), centred in the free space: Unread or Needs You with no
/// chat in that state, or sources that hold no chat (`docs/inbox.md` §5).
struct CaughtUpState: View {
    private let symbol: String
    private let title: String
    private let message: String

    /// Unread or Needs You narrowed everything away.
    init(scope: InboxScope) {
        symbol = "checkmark.circle.fill"
        if scope.needsYouOnly, !scope.unreadOnly {
            title = String(localized: "Nothing needs you")
            message = String(localized: "Hermes isn’t waiting on you in any chat.")
        } else {
            title = String(localized: "You’re all caught up")
            message = String(localized: "Nothing unread in your chats.")
        }
    }

    /// The sources picked hold no chat.
    init(sources: Void) {
        symbol = "line.3.horizontal.decrease.circle"
        title = String(localized: "No chats from these sources")
        message = String(localized: "Pick more sources in Filter, or show everything.")
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Menus

/// Mute ▸ For 1 Hour, For 8 Hours, For 1 Week, Until I Turn It Back On; or Unmute
/// (`docs/inbox.md` §1 Muting).
struct MuteMenu: View {
    let unread: UnreadStore
    let key: String

    var body: some View {
        if let end = unread.mutes.end(of: key) {
            Button(end == .distantFuture ? String(localized: "Unmute") : String(localized: "Unmute (until \(end.formatted(date: .omitted, time: .shortened)))"),
                   systemImage: "bell") {
                unread.unmute(key)
            }
        } else {
            Menu("Mute", systemImage: "bell.slash") {
                Button("For 1 Hour") { unread.mute(key, for: .hour) }
                Button("For 8 Hours") { unread.mute(key, for: .eightHours) }
                Button("For 1 Week") { unread.mute(key, for: .week) }
                Button("Until I Turn It Back On") { unread.mute(key, for: .untilTurnedOff) }
            }
        }
    }
}

/// "Settled “Release notes”  Undo" at the foot of the list, for 5 seconds (`docs/inbox.md` §5).
struct ArchivedToast: ViewModifier {
    @Bindable var workspace: BotWorkspace
    /// Room left below it: the chat list's bottom bar.
    var bottomPadding: CGFloat = 64
    let onError: (HermesError) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let session = workspace.recentlyArchived {
                HStack(spacing: 12) {
                    Text("Settled “\(session.displayTitle)”")
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Button("Undo") {
                        Task {
                            do {
                                try await workspace.unarchive(session)
                            } catch {
                                onError(error as? HermesError ?? .invalidResponse(error.localizedDescription))
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.sheetCell, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: Theme.shadow, radius: 12, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, bottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: session.stableID) {
                    AccessibilityNotification.Announcement(String(localized: "Settled \(session.displayTitle)")).post()
                    try? await Task.sleep(for: .seconds(5))
                    if workspace.recentlyArchived?.stableID == session.stableID {
                        withAnimation(Theme.snappy) { workspace.recentlyArchived = nil }
                    }
                }
            }
        }
        .animation(Theme.snappy, value: workspace.recentlyArchived?.stableID)
    }
}

#if os(iOS)
/// A pan that begins only when the finger moves more sideways than up or down (`SidewaysSwipe`),
/// so vertical drags stay the list's or the chat's. A SwiftUI drag on rows in a scroll view took
/// those too, and the list and the chat stopped scrolling.
struct SidewaysSwipePan: UIGestureRecognizerRepresentable {
    var direction = SidewaysSwipe.Direction.either
    /// Reports where the finger is across the view (a scrubber's) instead of how far it moved.
    var tracksLocation = false
    /// Reports how far the finger has moved since it touched down, the move that began the pan
    /// included, as a row's swipe actions must to keep up with it (`SidewaysSwipe.travel`).
    var countsFromTouchDown = false
    var isEnabled = true
    var began: () -> Void = {}
    /// How far the finger has moved across (or where it is, `tracksLocation`).
    let changed: (CGFloat) -> Void
    let ended: (_ x: CGFloat, _ velocity: CGFloat) -> Void
    /// The system took the touch, or the row went. Without it, the swipe ends where it is.
    var cancelled: (() -> Void)?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        if pan.isEnabled != isEnabled { pan.isEnabled = isEnabled }
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let x = if tracksLocation {
            context.converter.localLocation.x
        } else if countsFromTouchDown, let touchDown = context.coordinator.touchDown {
            SidewaysSwipe.travel(from: touchDown, to: pan.location(in: nil))
        } else {
            pan.translation(in: pan.view).x
        }
        switch pan.state {
        case .began:
            began()
            changed(x)
        case .changed:
            changed(x)
        case .ended:
            ended(x, pan.velocity(in: pan.view).x)
        case .cancelled, .failed:
            if let cancelled { cancelled() } else { ended(x, 0) }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// An open row's swipe goes either way: back to the right shuts it.
        var direction: SidewaysSwipe.Direction
        /// Where the finger touched down, in the window: the row may move under it.
        var touchDown: CGPoint?

        init(direction: SidewaysSwipe.Direction) {
            self.direction = direction
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return SidewaysSwipe.begins(velocity: pan.velocity(in: pan.view), translation: pan.translation(in: pan.view), direction: direction)
        }
    }
}
#endif
