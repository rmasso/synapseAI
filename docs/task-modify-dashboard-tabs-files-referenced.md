# Files read, grepped, or otherwise referenced — Modify Dashboard Tabs for Project Deletion

## Files read (full or partial)

| File | Purpose |
|------|---------|
| `SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift` | Full read to implement tab X, delete alert, remove-project helper; remove Remove button and alert from ProjectDashboardContent. |

## Grep / search

| Command / search | Location | Purpose |
|------------------|----------|---------|
| `struct SynapseProject\|class SynapseProject\|folderService\.projects` | `SynapseAI/` | Confirm project type name (`SynapseProject`) for `projectToDelete` state. |
| `tabItem\|TabView\|NSTab` | `SynapseAI/` | Find tab usage for X icon fix. |

## Files modified

| File | Changes |
|------|---------|
| `SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift` | Added delete state, tabItem HStack (then replaced with Label + context menu), TabView .alert, removeProjectToDelete(); removed Remove button, isShowingDeleteConfirmation, removeCurrentProject() from ProjectDashboardContent. |
| `docs/task-modify-dashboard-tabs-files-referenced.md` | This file: list of files read, grepped, modified. |

## Fix for X not visible on tabs (macOS)

On macOS, `TabView`’s `.tabItem` does not reliably show custom `HStack` content (only the first view or a single label is used). So:

- **Tab label:** Use a single `Label(project.name, systemImage: "xmark.circle")` so the tab shows the **X icon** plus the project name (and `⚠` in the title when index is stale).
- **Delete action:** A **context menu** on the tab content provides “Delete project” (right‑click the dashboard content of that tab). Same confirmation alert as before.
- To get a **clickable** X on the tab bar itself (not just visible), the UI would need a custom tab bar (e.g. `HStack` of tab pills with an X button each) instead of `TabView`.

## Other references (from skill / context)

- Skill: "Modify Dashboard Tabs for Project Deletion" (SwiftUI, macOS).
- `FolderService.removeProject(id:)`, `NodeBridgeService.setProject`, `SynapseProject` (id, name, path).
