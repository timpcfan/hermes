import HermesKit
import HermesPush
import SwiftUI

/// What a chat row shows, read from the workspace in one place so the iPhone's list and the
/// split view's sidebar draw the same words and state (`docs/inbox.md` §10). Every value is read
/// while the row draws, so an activity line or an unread mark moving redraws the row that owns it.
struct ChatRowReading {
    let session: HermesSession
    let workspace: BotWorkspace

    var key: String { session.stableID }

    var line: ActivityLine? { workspace.activity.line(for: key) }

    var isWaiting: Bool { workspace.waitingChat(forKey: key) != nil }

    var state: ChatRowState {
        ChatRowState(line: line, isWaiting: isWaiting, isUnread: isUnread,
                     endedAt: session.endedAt, lastActive: session.lastActive)
    }

    var profile: String {
        ProfileRows.profileName(of: session, home: workspace.bot.profileName)
    }

    var subtitle: String {
        ChatRowSubtitle.text(source: session.source, profile: profile, project: session.projectName)
    }

    var isUnread: Bool {
        let badge = workspace.unread.badge(for: key)
        let marked = badge.isUnread || workspace.unread.readMark(for: key) == .markedUnread
        // A running turn is its own news; the dot comes back when it lands.
        return marked && !(line?.isLive == true)
    }

    var isMuted: Bool { workspace.unread.isMuted(key) }

    /// The chat's model, when the gateway serves one. The reasoning level stays out of the row
    /// (`docs/inbox.md` §10): beside the profile it read as noise.
    var modelLine: String? {
        ChatRowSubtitle.modelLine(model: session.model)
    }

    /// When the running turn started, best first: the attached conversation's turn, the moment the
    /// message went out here, the first sight of the chat running this launch, then the session's
    /// own last activity (the prompt that started the turn). The earliest of the fallbacks wins, so
    /// a session that updates while a reply streams doesn't restart the clock.
    var startedAt: Date? {
        if let started = workspace.loadedConversation(forKey: key)?.live?.turn.startedAt { return started }
        if isWaiting, let sent = workspace.lastSentAt[key] { return sent }
        let seen = workspace.activity.runningStart(for: key)
        return [seen, session.lastActive].compactMap { $0 }.min()
    }

    /// The row as VoiceOver reads it: the title, where it came from, its model, its marks, then
    /// what it is doing.
    var spoken: String {
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
                Image(platformImage: image)
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
    /// The iPhone's `.footnote`; the sidebar's smaller type passes its own.
    var font = Font.footnote.weight(.semibold)

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
        .font(font)
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
