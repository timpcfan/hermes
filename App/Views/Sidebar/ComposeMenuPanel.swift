#if os(iOS)
import SwiftUI

/// A menu that hangs by the compose circle or the chat screen's pencil, drawn here instead of as a
/// system popover (`docs/inbox.md` §9). iOS puts a popover's arrow on the control it hangs from,
/// and when that arrow lands near the screen's edge it squares the panel's corner above it, so the
/// menu looked cut off on the bottom right. This panel draws its own four corners and no arrow. It
/// keeps the popover's look: the rows are the same (`IOSMenuRows`), the material is the system's,
/// and a tap outside closes it.
struct ComposeMenuPanel<Content: View>: View {
    /// How wide the rows may run before they wrap (the window, less a margin).
    var maxWidth: CGFloat
    /// The screen edge the panel hangs by: `.bottom` above the compose circle, `.top` under the
    /// chat screen's pencil.
    var edge: VerticalEdge
    /// Clear of whatever the panel must not cover on that edge (the circle floating over a list).
    var inset: CGFloat = 8
    let onDismiss: () -> Void
    @ViewBuilder var content: Content

    private var anchor: UnitPoint { edge == .bottom ? .bottomTrailing : .topTrailing }
    private var alignment: Alignment { edge == .bottom ? .bottomTrailing : .topTrailing }

    var body: some View {
        ZStack(alignment: alignment) {
            // Invisible, but it takes the taps: a tap anywhere but the panel closes it, as a
            // popover's does. Its 0.001 clear keeps the hit area without dimming the screen.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            IOSMenuRows(maxWidth: maxWidth) { content }
                .labelStyle(IOSMenuRowLabelStyle())
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                // Liquid Glass, as the system's own popovers and the rest of this app draw it
                // (`SidebarOverChat.panel`), rather than a plain material blur.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Theme.shadow, radius: 20, y: 12)
                .padding(.horizontal, 10)
                .padding(edge == .bottom ? .bottom : .top, inset)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: anchor)))
        }
    }
}
#endif
