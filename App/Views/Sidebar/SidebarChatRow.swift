import HermesKit
import SwiftUI

/// A chat in the split view's sidebar, on iPad and the Mac: three lines (`docs/inbox.md` §2).
///
/// ```
/// [•] default                                    2h
///     Fix the RSS feed dates
///     app                                  qwen4-max
/// ```
///
/// Line one is whose chat it is — the profile's face at thumbnail size and its name — with the
/// state in the corner. Line two is the title, which wraps to two lines. Line three is where the
/// chat came from, with the model that ran it at the line's end. No last-message preview: the
/// sidebar's rows are about which chat and what state.
///
/// The words and the state come from the shared `ChatRowReading`, so the two lists can't say
/// different things.
struct SidebarChatRow: View {
    let session: HermesSession
    let workspace: BotWorkspace

    var body: some View {
        let row = ChatRowReading(session: session, workspace: workspace)
        VStack(alignment: .leading, spacing: SidebarMetrics.chatLineSpacing) {
            HStack(alignment: .center, spacing: 6) {
                if session.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: SidebarMetrics.chatGlyphSize))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
                ChatProfileAvatar(profile: row.profile, workspace: workspace, isUnread: row.isUnread,
                                  size: SidebarMetrics.chatFaceSize)
                Text(row.profile)
                    .font(SidebarMetrics.chatDetailFont.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    // A short name ("default") stays whole beside a long state ("Needs you") by
                    // giving up a little size rather than its last letters (`docs/inbox.md` §2).
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                ChatRowStatusBadge(state: row.state, startedAt: row.startedAt,
                                   font: SidebarMetrics.chatDetailFont.weight(.semibold),
                                   showsWorkingWord: true)
            }
            title(row)
                .padding(.top, 1)
            HStack(spacing: 4) {
                Image(systemName: InboxSourceGroup(source: session.source).symbol)
                    .font(.system(size: SidebarMetrics.chatGlyphSize))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                Text(SidebarChatRow.sourceText(session))
                    .font(SidebarMetrics.chatMetaFont)
                    .foregroundStyle(Theme.tertiaryText)
                    // A source word is short ("app", "terminal"): it never gives up letters, the
                    // long model name beside it truncates first (`docs/inbox.md` §2).
                    .fixedSize(horizontal: true, vertical: false)
                // The model closes the line, flush right (`docs/inbox.md` §2). In a 240 pt sidebar a
                // long id is cut at the tail rather than shrinking: one row at 10.7 pt and the next
                // at 13 pt reads as a mistake.
                if let modelLine = row.modelLine {
                    Spacer(minLength: 8)
                    Text(modelLine)
                        .font(SidebarMetrics.chatMetaFont)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 2)
            if case .failed(let reason) = row.state {
                Text(reason)
                    .font(SidebarMetrics.chatDetailFont)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }

    /// Line three's left side: where the chat came from — "app", "terminal", "telegram". The
    /// profile already speaks for itself on line one, so it isn't repeated here.
    static func sourceText(_ session: HermesSession) -> String {
        ChatRowSubtitle.platformName(session.source) ?? ""
    }

    private func title(_ row: ChatRowReading) -> some View {
        Text(session.displayTitle)
            .font(SidebarMetrics.chatTitleFont)
            .fixedSize(horizontal: false, vertical: true)
            // While Hermes works the status in the corner is the thing to read.
            .foregroundStyle(row.state == .running ? Theme.secondaryText : Theme.primaryText)
            .lineLimit(2)
    }
}
