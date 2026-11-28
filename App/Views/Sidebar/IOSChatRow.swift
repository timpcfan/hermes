import HermesKit
import SwiftUI

/// A chat in the iPhone's list (`mockup-v2.html`): two lines, the shape the person asked for.
///
/// ```
/// Fix the RSS feed dates                              2h
/// (face) default                              qwen4-max
/// ```
///
/// Line one is the title, wrapping to two lines, with the state in the corner. Line two opens with
/// the profile's small face and its name and closes with the model flush right. The app the chat
/// came from isn't drawn — the profile takes its place at the left edge, and the source is one tap
/// away in the chat (`docs/inbox.md` §10).
///
/// The left side is one row's own state: it reads its activity line through `ChatRowReading`, so a
/// reply streaming in another chat redraws that row, not this one (`docs/inbox.md` §3).
struct IOSChatRow: View {
    let session: HermesSession
    let workspace: BotWorkspace

    /// The width a pinned row's pin takes on both lines, so a pinned chat's title and its face
    /// start at the same x (`docs/inbox.md` §10).
    private static let pinWidth: CGFloat = 10

    var body: some View {
        let row = ChatRowReading(session: session, workspace: workspace)
        VStack(alignment: .leading, spacing: InboxMetrics.lineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                pinSlot
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
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }

    /// The pin, in a slot of its own on line one. Line two leaves the same slot empty
    /// (`pinGutter`), which is what keeps a pinned chat's two lines flush (`pinWidth`).
    @ViewBuilder private var pinSlot: some View {
        if session.pinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(Theme.warning)
                .frame(width: Self.pinWidth)
                .accessibilityHidden(true)
        }
    }

    /// Line two's half of a pinned row's pin slot: as wide as the pin, and invisible.
    @ViewBuilder private var pinGutter: some View {
        if session.pinned {
            Color.clear
                .frame(width: Self.pinWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    private func title(_ row: ChatRowReading) -> some View {
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

    /// Line two: the profile's face at a thumbnail's size, then its name, then the model flush
    /// right (`docs/inbox.md` §10). The source's glyph isn't drawn — the profile takes its place.
    private func subtitleLine(_ row: ChatRowReading) -> some View {
        HStack(spacing: 8) {
            pinGutter
            ChatProfileAvatar(profile: row.profile, workspace: workspace,
                              size: InboxMetrics.rowFaceSize)
            Text(row.profile)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let modelLine = row.modelLine {
                Spacer(minLength: 8)
                Text(modelLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
    }
}
