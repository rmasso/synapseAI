# System Patterns

## Architecture Overview
- **SwiftUI app (SynapseAI)** – Menu bar only (LSUIElement); MenuBarExtra + WindowGroup("Dashboard", id: "dashboard"). No dock icon.
- **Node bridge** – Subprocess; stdin/stdout JSON-RPC. Methods: `ping`, `setProject`, `indexFile`, `indexAll`, `search`, `suggestSkill`, `suggestLearnings`, `buildContextForPrompt`, `buildSubagentContext`, `getStats`. File-change events: `fileChanged`.
- **Per-project data** – `.synapse/` (created by Swift FolderService + Node `synapse-init.js`); `.synapse/synapse.db` (better-sqlite3 + FTS5); `.synapse/skills/`, `.synapse/ingested/`.

## Key Technical Decisions
1. **Swift ↔ Node IPC** – JSON-RPC over stdin/stdout; single Node process; request/response by `id`; notifications (e.g. fileChanged) have no `id`.
2. **Chunking** – Markdown split by headers and size (~1200 chars) in `node/chunk.js`; line ranges stored for @file refs.
3. **Search** – FTS5 + bm25() in `node/search.js`; top-k snippets; cap total size (e.g. 8 KB) when building injection block.
4. **Paste** – AccessibilityService finds Cursor (bundle ID or name), gets kAXFocusedUIElement, sets kAXValueAttribute; fallback: NSPasteboard.
5. **Hotkey** – NSEvent.addGlobalMonitorForEvents for ⌘⇧P; requires Accessibility permission for Synapse.
6. **Dashboard window** – Reuse single window: check `NSApp.windows.first(where: { $0.title == "Dashboard" })` before calling `openWindow(id: "dashboard")`.

## Design Patterns in Use
- **MVVM** – Views bind to ViewModels; ViewModels call Services; no business logic in Views.
- **Singleton services** – NodeBridgeService.shared, FolderService.shared, AccessibilityService.shared, HotkeyService.shared.
- **Security-scoped bookmarks** – FolderService stores project path and bookmark; creates `.synapse/` and templates in Swift; Node receives path and runs chokidar + DB in that tree (sandbox may limit Node’s access; Swift has scope).

## Component Relationships
- **App** – Registers hotkey (init); AppDelegate unregisters on terminate. Run injection uses NodeBridgeService.search + AccessibilityService.paste.
- **MenuBarView** – Open Project (FolderService + NodeBridge setProject); Open Dashboard (find window or openWindow); Quit.
- **DashboardView** – Index All, Search, Drag-drop ingest, Grok Suggest Skill; displays status, memory files, thoughts, tokens, search results + Copy block.
- **Node** – index.js routes RPC; setProject → initSynapseFolder + db.open + watch; indexFile/indexAll → chunk + upsertDocument; search → FTS5. **buildContextForPrompt:** FTS + suggestChunksForPrompt → getChunksById, dbSnippets + memorySnippets (grok.readSynapseFilesAsContext: projectbrief, activeContext, progress, thoughts, learnings) → grok.buildSkillFormatPrompt → skill.md block; fallback legacy @file block. **buildSubagentContext:** memorySnippets + smaller DB search → grok.buildSubagentContext (memory-heavy prompt). suggestSkill → grok.suggestAndCreateSkill + index; suggestLearnings → grok.suggestLearnings + append learnings.md.
