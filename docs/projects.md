# Projects (removed in this fork)

This fork of Hermes has no Projects. The Chats sidebar is one inbox that holds every chat, by what
it needs from you (`docs/inbox.md` §2a), so the projects that kept some chats apart, and everything
that only served them, are gone:

- the sidebar's Projects section, All Projects, a project's home and the Mac's project rows;
- the composer's project chip and Run In, and the chat menu's Move to Project…;
- search's Projects filter and project results, and the ⌘K palette's projects and ⌘1–⌘3;
- the welcome flow's "Make … a project" starting point, and Projects and Board in Settings → Setup;
- the Board's screens, which opened only from a project. A card's notification or
  `hermesapp://board/…` link opens the chat list; a chat still says which cards Hermes added.

What stays, and why:

- `ProjectsModel` (`App/Model/ProjectsModel.swift`) keeps two things: `session.active_list`, the one
  place the app learns what runs elsewhere on the gateway (`LiveActivity`, the inbox's Working
  region), and the gateway's default folder, where a new chat starts and the Inspector's files
  open.
- A new chat names no folder: Hermes starts it in its default one.
- HermesKit's project types (`ProjectsClient`, `ProjectModels`, the project cases of `SidebarItem`
  and `DetailRoute`) are kept as they were, with their tests: a window restored onto a project
  screen, or a launch flag naming one, opens nothing (`SidebarItem.isProjectScreen`).
- Projects made in Hermes Desktop or elsewhere are untouched on the gateway; their chats show in the
  inbox like any other.

The upstream document for Projects is in the history of `docs/projects.md` before this change.
