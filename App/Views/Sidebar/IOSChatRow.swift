import HermesKit
import SwiftUI

/// A chat in the iPhone's list (`mockup-v2.html`): the profile's avatar with the unread dot on its
/// corner, the title and pin, where the chat came from, then what it is doing — running with its
/// time, done while its news is unread, how long ago it ended once read, waiting on the person, or
/// failed with the reason in red (`docs/inbox.md` §10).
///
/// The left side is one row's own state: it reads its activity line through `ChatRowReading`, so a
/// reply streaming in another chat redraws that row, not this one (`docs/inbox.md` §3).
struct IOSChatRow: View {
    let session: HermesSession
    let workspace: BotWorkspace

    var body: some View {
        let row = ChatRowReading(session: session, workspace: workspace)
        HStack(alignment: .top, spacing: 12) {
            ChatProfileAvatar(profile: row.profile, workspace: workspace, isUnread: row.isUnread)
            VStack(alignment: .leading, spacing: InboxMetrics.lineSpacing) {
                HStack(alignment: .top, spacing: 8) {
                    title(row)
                    Spacer(minLength: 0)
                    ChatRowStatusBadge(state: row.state, startedAt: row.startedAt)
                        .padding(.top, 1)
                }
                subtitleLine(row)
                if case .failed(let reason) = row.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }

    private func title(_ row: ChatRowReading) -> some View {
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
                .foregroundStyle(row.state == .running ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(2)
        }
    }

    private func subtitleLine(_ row: ChatRowReading) -> some View {
        HStack(spacing: 4) {
            Image(systemName: InboxSourceGroup(source: session.source).symbol)
                .font(.system(size: InboxMetrics.glyphSize))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(row.subtitle)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            // The model closes the same line (`docs/inbox.md` §10): the profile reads from the
            // left edge, the model sits flush right.
            if let modelLine = row.modelLine {
                Spacer(minLength: 8)
                Text(modelLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
    }
}
