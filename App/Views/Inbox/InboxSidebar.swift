import HermesKit
import SwiftUI

// The Chats inbox's region parts (`docs/inbox.md` §2a, after t3code's sidebar): the Working and
// Settled headers, Settled's slim rows and its paging. They are plain rows of the one sidebar
// `List`, not `Section`s, so the list keeps one identity and a collapsed region keeps no rows.

/// "Working 2 ⌄" / "Settled 73 ›": a region's header, which folds it. The count sits by the
/// chevron, as in t3code; a dot says something moved in a folded Settled.
struct InboxRegionHeader: View {
    let title: String
    let count: Int?
    @Binding var isExpanded: Bool
    /// A settled chat ran elsewhere since it was settled (never an unread count).
    var showsActivity = false

    var body: some View {
        Button {
            withAnimation(Theme.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if showsActivity {
                    Circle()
                        .fill(Theme.secondaryText)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .font(SidebarMetrics.sectionFont)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarRowInsets())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityLabel: Text {
        var label = Text(title)
        if let count { label = Text("\(label), \(count)") }
        if showsActivity { label = Text("\(label), new activity") }
        return label
    }
}
