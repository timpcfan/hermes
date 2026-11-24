import HermesKit
import SwiftUI

/// Cards Hermes added from a chat (`cardsAddedNote`): each with where it landed.
struct CardsAddedNote: View {
    let cards: [BoardAddedCard]
    let context: MemoryNoteContext

    private var workspace: BotWorkspace { context.workspace }

    /// Where they landed is all the note says: this build has no Board screen to open
    /// (`docs/projects.md`).
    private var title: String {
        String(localized: "Added \(BoardCopy.cards(cards.count)) to the board")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cards) { card in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.tertiaryText)
                            .frame(width: 5, height: 5)
                        Text(card.title)
                            .font(.footnote)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(place(of: card))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    // The note's last element can end the reply: where VoiceOver lands reading back
                    // (`docs/chat.md` §1).
                    .modifier(VoiceOverLandingTarget(isLast: card.id == cards.last?.id))
                }
            }
            .padding(.vertical, 3)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// "Ready · Ada", "Ready", "After 2 cards": as Hermes reported it when it added the card.
    private func place(of card: BoardAddedCard) -> String {
        if card.isWaiting && card.column == "todo" {
            let count = card.parentCount
            return count == 1 ? String(localized: "After 1 card") : String(localized: "After \(count) cards")
        }
        let columnTitle = BoardColumn(key: card.column, label: card.column).title
        let assignee = card.assignee
        let isHermes = assignee == nil || assignee == "default" || workspace.roster?.bot(named: assignee ?? "")?.isDefault == true
        guard !isHermes, let assignee else { return columnTitle }
        return "\(columnTitle) · \(assignee.capitalized)"
    }
}
