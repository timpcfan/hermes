import HermesKit
import SwiftUI

/// A chat in the split view's sidebar, on iPad and the Mac: the iPhone's row (`IOSChatRow`) at a
/// sidebar's size (`docs/inbox.md` §2). The profile's face with the unread dot on its corner, the
/// pin and a title that wraps to two lines, where the chat came from with the model it ran with at
/// the line's end, and what it is doing in the top corner.
///
/// No last-message preview: the sidebar's rows are about which chat and what state, and the
/// person reads the conversation itself (`_brief/BRIEF-SIDEBAR.md`). The words and the state come
/// from the shared `ChatRowReading`, so the two lists can't say different things.
struct SidebarChatRow: View {
    let session: HermesSession
    let workspace: BotWorkspace

    var body: some View {
        let row = ChatRowReading(session: session, workspace: workspace)
        HStack(alignment: .top, spacing: 10) {
            ChatProfileAvatar(profile: row.profile, workspace: workspace, isUnread: row.isUnread,
                              size: SidebarMetrics.chatFaceSize)
            VStack(alignment: .leading, spacing: SidebarMetrics.chatLineSpacing) {
                HStack(alignment: .top, spacing: 8) {
                    title(row)
                    Spacer(minLength: 0)
                    ChatRowStatusBadge(state: row.state, startedAt: row.startedAt,
                                       font: SidebarMetrics.chatDetailFont.weight(.semibold))
                        .padding(.top, 1)
                }
                subtitleLine(row)
                if case .failed(let reason) = row.state {
                    Text(reason)
                        .font(SidebarMetrics.chatDetailFont)
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
                .font(SidebarMetrics.chatTitleFont)
                .fixedSize(horizontal: false, vertical: true)
                // While Hermes works the status in the corner is the thing to read.
                .foregroundStyle(row.state == .running ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(2)
        }
    }

    private func subtitleLine(_ row: ChatRowReading) -> some View {
        HStack(spacing: 4) {
            Image(systemName: InboxSourceGroup(source: session.source).symbol)
                .font(.system(size: SidebarMetrics.chatGlyphSize))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(row.subtitle)
                .font(SidebarMetrics.chatDetailFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            // The model closes the same line, flush right (`docs/inbox.md` §2): the profile gives
            // way first, so a narrow sidebar keeps the model whole.
            if let modelLine = row.modelLine {
                Spacer(minLength: 8)
                Text(modelLine)
                    .font(SidebarMetrics.chatDetailFont)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
    }
}
