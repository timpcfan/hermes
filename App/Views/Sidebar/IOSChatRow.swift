#if os(iOS)
import HermesKit
import HermesPush
import SwiftUI

/// A chat in the iPhone's list (`mockup-v2.html`): the profile's avatar with the unread dot on its
/// corner, the title and pin, where the chat came from, then what it is doing — running with its
/// time, done while its news is unread, how long ago it ended once read, waiting on the person, or
/// failed with the reason in red (`docs/inbox.md` §10).
///
/// The left side is one row's own state: it reads its activity line through `line(for:)`, so a
/// reply streaming in another chat redraws that row, not this one (`docs/inbox.md` §3).
struct IOSChatRow: View {
    let session: HermesSession
    let workspace: BotWorkspace

    private var key: String { session.stableID }
    private var line: ActivityLine? { workspace.activity.line(for: key) }
    private var isWaiting: Bool { workspace.waitingChat(forKey: key) != nil }

    private var state: ChatRowState {
        ChatRowState(line: line, isWaiting: isWaiting, isUnread: isUnread,
                     endedAt: session.endedAt, lastActive: session.lastActive)
    }

    private var profile: String {
        ProfileRows.profileName(of: session, home: workspace.bot.profileName)
    }

    private var subtitle: String {
        ChatRowSubtitle.text(source: session.source, profile: profile, project: session.projectName)
    }

    private var isUnread: Bool {
        let badge = workspace.unread.badge(for: key)
        let marked = badge.isUnread || workspace.unread.readMark(for: key) == .markedUnread
        // A running turn is its own news; the dot comes back when it lands.
        return marked && !(line?.isLive == true)
    }

    private var isMuted: Bool { workspace.unread.isMuted(key) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChatProfileAvatar(profile: profile, workspace: workspace, isUnread: isUnread)
            VStack(alignment: .leading, spacing: InboxMetrics.lineSpacing) {
                HStack(alignment: .top, spacing: 8) {
                    title
                    Spacer(minLength: 0)
                    ChatRowStatusBadge(state: state, startedAt: startedAt)
                        .padding(.top, 1)
                }
                subtitleLine
                if case .failed(let reason) = state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The chat's model and effort, when the gateway serves either.
    private var modelLine: String? {
        ChatRowSubtitle.modelLine(model: session.model, effort: session.reasoningEffort)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if session.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            }
            Text(session.displayTitle)
                // The Bots tab's title size (`InboxMetrics.unreadTitleFont`), up to two lines: a
                // long title wraps instead of pushing the status on the right out of its corner.
                .font(InboxMetrics.unreadTitleFont)
                .fixedSize(horizontal: false, vertical: true)
                // Running fades the title, as the design draws it: the status on the right is the
                // thing to read while Hermes works.
                .foregroundStyle(state == .running ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(2)
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            Image(systemName: InboxSourceGroup(source: session.source).symbol)
                .font(.system(size: InboxMetrics.glyphSize))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            // The model and effort close the same line (`docs/inbox.md` §10): the profile reads
            // from the left edge, the model sits flush right.
            if let modelLine {
                Spacer(minLength: 8)
                Text(modelLine)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
    }

    /// When the running turn started, best first: the attached conversation's turn, the moment the
    /// message went out here, the first sight of the chat running this launch, then the session's
    /// own last activity (the prompt that started the turn). The earliest of the fallbacks wins, so
    /// a session that updates while a reply streams doesn't restart the clock.
    private var startedAt: Date? {
        if let started = workspace.loadedConversation(forKey: key)?.live?.turn.startedAt { return started }
        if isWaiting, let sent = workspace.lastSentAt[key] { return sent }
        let seen = workspace.activity.runningStart(for: key)
        return [seen, session.lastActive].compactMap { $0 }.min()
    }

    private var spoken: String {
        var parts = [session.displayTitle, subtitle]
        if let modelLine { parts.append(modelLine) }
        if isUnread { parts.append(String(localized: "unread")) }
        if session.pinned { parts.append(String(localized: "pinned")) }
        if isMuted { parts.append(String(localized: "muted")) }
        switch state {
        case .running:
            if let startedAt {
                parts.append(String(localized: "running for \(ChatRowDuration.short(Date.now.timeIntervalSince(startedAt)))"))
            } else {
                parts.append(String(localized: "running"))
            }
        case .done:
            parts.append(String(localized: "done"))
        case .ended(let date):
            if let date { parts.append(String(localized: "ended \(Formatting.relativePhrase(date))")) }
        case .needsYou:
            parts.append(String(localized: "needs you"))
        case .failed(let reason):
            parts.append(String(localized: "failed"))
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }
}

/// The profile's avatar: its Bot's photo or drawn face when it has one, otherwise its first letter
/// on the name's stable colour. The unread dot sits on the corner.
struct ChatProfileAvatar: View {
    let profile: String
    let workspace: BotWorkspace
    let isUnread: Bool
    var size: CGFloat = InboxMetrics.faceSize

    private var appearance: BotAppearance? {
        guard let roster = workspace.roster, let bot = roster.bot(named: profile) else { return nil }
        return roster.appearance(for: bot)
    }

    var body: some View {
        Group {
            if let appearance, let source = appearance.imageURL, FaceImageCache.canDraw(source),
               let image = FaceImageCache.image(for: source) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else if let appearance {
                StillFace(look: appearance.look, size: size)
                    .frame(width: size, height: size)
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if isUnread {
                Circle()
                    .fill(Palette.Faces.unread)
                    .frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(Theme.canvas, lineWidth: 2) }
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let color = ProfileMonogram.color(for: profile)
        return RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(color))
            .overlay {
                Text(ProfileMonogram.initial(profile))
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(Color(color.eye))
            }
    }
}

/// The row's trailing state: a dashed green ring and the running time, a green check and Done, how
/// long ago a read chat ended, an orange mark and Needs you, or a red mark and Failed.
struct ChatRowStatusBadge: View {
    let state: ChatRowState
    let startedAt: Date?

    var body: some View {
        Group {
            switch state {
            case .running:
                if let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        label(text: ChatRowDuration.short(context.date.timeIntervalSince(startedAt)), color: Theme.success) {
                            DashedStatusRing()
                        }
                    }
                } else {
                    label(text: String(localized: "Working"), color: Theme.success) {
                        DashedStatusRing()
                    }
                }
            case .done:
                label(symbol: "checkmark.circle", text: String(localized: "Done"), color: Theme.success)
            case .ended(let date):
                if let date { ChatRowAgoText(date: date) }
            case .needsYou:
                label(symbol: "exclamationmark.circle.fill", text: String(localized: "Needs you"), color: Theme.warning)
            case .failed:
                label(symbol: "exclamationmark.circle.fill", text: String(localized: "Failed"), color: Theme.danger)
            }
        }
        // The Bots rows' time size, one weight up: the two tabs read as one list (`docs/inbox.md` §10).
        .font(.footnote.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func label(symbol: String, text: String, color: Color) -> some View {
        label(text: text, color: color) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
        }
    }

    private func label(text: String, color: Color, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 5) {
            icon()
            Text(text)
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

/// How long ago a read chat ended ("2h", "3d"), quiet beside the other states. It redraws only
/// when its words change, never on a clock.
struct ChatRowAgoText: View {
    let date: Date

    var body: some View {
        TimelineView(Schedule(date: date)) { context in
            Text(ChatRowAgo.text(context.date.timeIntervalSince(date)))
                .fontWeight(.regular)
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    /// The moments the words change (`ChatRowAgo.nextChange`), and only those.
    nonisolated struct Schedule: TimelineSchedule {
        let date: Date

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
            AnySequence(sequence(first: startDate) { [date] now in
                date.addingTimeInterval(ChatRowAgo.nextChange(after: now.timeIntervalSince(date)))
            })
        }
    }
}

/// The running turn's dashed ring (`mockup-v2.html`): still, never a spinner.
struct DashedStatusRing: View {
    var body: some View {
        Circle()
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3.4, 2.8]))
            .frame(width: 15, height: 15)
    }
}
#endif
